-----------------------------------------------------------
-- TOKEN BUCKET RATE LIMITING (Per-Player)
-- Algorithm: Each player has a bucket with max 5 tokens
-- Tokens refill at 1 per 12 seconds (5 per minute)
-- Each AI request consumes 1 token
-----------------------------------------------------------
local playerBuckets = {}  -- { [playerId] = { tokens, lastRefill } }
local requestQueue = {}
local isProcessingQueue = false
local lastRequestTime = 0
local pendingRequests = {}  -- Track pending requests per player
local currentConcurrent = 0

-- Token Bucket configuration (per-player limits)
local TOKEN_BUCKET = {
    maxTokens = 5,              -- Max tokens per player (burst capacity)
    refillRate = 5,             -- Tokens per minute
    refillIntervalMs = 12000,   -- 1 token every 12 seconds (60000/5)
}

-- Global stagger configuration (prevents API burst)
local GLOBAL_STAGGER = {
    minDelayMs = 300,           -- Minimum ms between any API calls
    maxConcurrent = 5,          -- Max concurrent API requests
    requestTimeoutMs = 30000    -- 30 second timeout per request
}

-----------------------------------------------------------
-- Token Bucket Management
-----------------------------------------------------------
function GetPlayerBucket(playerId)
    local currentTime = GetGameTimer()

    if not playerBuckets[playerId] then
        -- Initialize new bucket at full capacity
        playerBuckets[playerId] = {
            tokens = TOKEN_BUCKET.maxTokens,
            lastRefill = currentTime
        }
    end

    local bucket = playerBuckets[playerId]

    -- Refill tokens based on time elapsed
    local elapsed = currentTime - bucket.lastRefill
    local tokensToAdd = math.floor(elapsed / TOKEN_BUCKET.refillIntervalMs)

    if tokensToAdd > 0 then
        bucket.tokens = math.min(TOKEN_BUCKET.maxTokens, bucket.tokens + tokensToAdd)
        bucket.lastRefill = bucket.lastRefill + (tokensToAdd * TOKEN_BUCKET.refillIntervalMs)
    end

    return bucket
end

function ConsumeToken(playerId)
    local bucket = GetPlayerBucket(playerId)

    if bucket.tokens > 0 then
        bucket.tokens = bucket.tokens - 1
        return true
    end

    return false
end

function GetTokensRemaining(playerId)
    local bucket = GetPlayerBucket(playerId)
    return bucket.tokens
end

function GetTimeUntilNextToken(playerId)
    local bucket = GetPlayerBucket(playerId)
    if bucket.tokens >= TOKEN_BUCKET.maxTokens then
        return 0
    end

    local currentTime = GetGameTimer()
    local elapsed = currentTime - bucket.lastRefill
    local remaining = TOKEN_BUCKET.refillIntervalMs - elapsed

    return math.max(0, remaining)
end

-----------------------------------------------------------
-- Request Queue with Token Bucket
-----------------------------------------------------------
function QueueAIRequest(playerId, conversation, playerMessage)
    -- Check if player already has a pending request
    if pendingRequests[playerId] then
        TriggerClientEvent('ai-npcs:client:receiveMessage', playerId,
            "*holds up a finger* Hold on, I'm still thinking...", conversation.npc.id)
        return
    end

    -- Check if player has tokens available
    local tokensRemaining = GetTokensRemaining(playerId)

    if tokensRemaining <= 0 then
        -- No tokens - inform player and queue anyway (will process when token available)
        local waitTime = math.ceil(GetTimeUntilNextToken(playerId) / 1000)
        TriggerClientEvent('ai-npcs:client:receiveMessage', playerId,
            ("*seems busy* Give me a moment... (%ds)"):format(waitTime), conversation.npc.id)

        if Config.Debug.enabled then
            print(("[AI NPCs] Player %s rate limited - %d tokens, wait %ds"):format(
                playerId, tokensRemaining, waitTime))
        end
    end

    -- Add to queue
    table.insert(requestQueue, {
        playerId = playerId,
        conversation = conversation,
        playerMessage = playerMessage,
        queuedAt = GetGameTimer()
    })

    pendingRequests[playerId] = true

    -- Start processing if not already
    if not isProcessingQueue then
        ProcessRequestQueue()
    end
end

function ProcessRequestQueue()
    if #requestQueue == 0 then
        isProcessingQueue = false
        return
    end

    isProcessingQueue = true
    local currentTime = GetGameTimer()

    -- Check global concurrent limit (stagger)
    if currentConcurrent >= GLOBAL_STAGGER.maxConcurrent then
        SetTimeout(500, ProcessRequestQueue)
        return
    end

    -- Check global minimum delay (stagger)
    local timeSinceLastRequest = currentTime - lastRequestTime
    if timeSinceLastRequest < GLOBAL_STAGGER.minDelayMs then
        SetTimeout(GLOBAL_STAGGER.minDelayMs - timeSinceLastRequest, ProcessRequestQueue)
        return
    end

    -- Find next request that has tokens available
    local requestIndex = nil
    for i, request in ipairs(requestQueue) do
        -- Check if request is too old (player might have left)
        if currentTime - request.queuedAt > 60000 then
            pendingRequests[request.playerId] = nil
            table.remove(requestQueue, i)
            -- Recurse to check next
            SetTimeout(0, ProcessRequestQueue)
            return
        end

        -- Check if player has tokens
        if GetTokensRemaining(request.playerId) > 0 then
            requestIndex = i
            break
        end
    end

    if not requestIndex then
        -- No requests with available tokens - wait for token refill
        local minWait = TOKEN_BUCKET.refillIntervalMs
        for _, request in ipairs(requestQueue) do
            local wait = GetTimeUntilNextToken(request.playerId)
            if wait < minWait then
                minWait = wait
            end
        end

        if Config.Debug.enabled then
            print(("[AI NPCs] All players rate-limited, waiting %dms for token refill"):format(minWait))
        end

        SetTimeout(minWait + 100, ProcessRequestQueue)
        return
    end

    -- Get the request and consume token
    local request = table.remove(requestQueue, requestIndex)

    if not ConsumeToken(request.playerId) then
        -- Token was consumed between check and now (race condition), requeue
        table.insert(requestQueue, 1, request)
        SetTimeout(100, ProcessRequestQueue)
        return
    end

    -- Process the request
    lastRequestTime = currentTime
    currentConcurrent = currentConcurrent + 1

    if Config.Debug.enabled then
        print(("[AI NPCs] Processing request for player %s (%d tokens remaining)"):format(
            request.playerId, GetTokensRemaining(request.playerId)))
    end

    GenerateAIResponseInternal(request.playerId, request.conversation, request.playerMessage, function()
        currentConcurrent = currentConcurrent - 1
        pendingRequests[request.playerId] = nil
        -- Process next request with stagger delay
        SetTimeout(GLOBAL_STAGGER.minDelayMs, ProcessRequestQueue)
    end)
end

-----------------------------------------------------------
-- Cleanup disconnected players
-----------------------------------------------------------
AddEventHandler('playerDropped', function(reason)
    local playerId = source
    playerBuckets[playerId] = nil
    pendingRequests[playerId] = nil

    -- Remove any queued requests for this player
    for i = #requestQueue, 1, -1 do
        if requestQueue[i].playerId == playerId then
            table.remove(requestQueue, i)
        end
    end
end)

-----------------------------------------------------------
-- FALLBACK DIALOGUE SYSTEM (uses Config.FallbackResponses)
-----------------------------------------------------------
function GetFallbackResponse(npc, reason)
    local category = "generic"

    -- Determine category based on NPC trust category
    if npc.trustCategory then
        if npc.trustCategory == "criminal" or npc.trustCategory == "gang" then
            category = "criminal"
        elseif npc.trustCategory == "professional" or npc.trustCategory == "legitimate" then
            category = "legitimate"
        elseif npc.trustCategory == "service" then
            category = "service"
        end
    end

    -- Use API error messages for actual failures
    if reason == "api_error" or reason == "timeout" then
        category = "api_error"
    end

    -- Get from config, fallback to generic if category missing
    local responses = Config.FallbackResponses and Config.FallbackResponses[category]
    if not responses or #responses == 0 then
        responses = Config.FallbackResponses and Config.FallbackResponses.generic
    end

    -- Ultimate fallback if config is missing entirely
    if not responses or #responses == 0 then
        return "*looks distracted* Sorry, what were you saying?"
    end

    return responses[math.random(#responses)]
end

-----------------------------------------------------------
-- AI Response Generation with Full Context
-----------------------------------------------------------
function GenerateAIResponse(playerId, conversation, playerMessage)
    -- Use the queue system instead of direct call
    QueueAIRequest(playerId, conversation, playerMessage)
end

function GenerateAIResponseInternal(playerId, conversation, playerMessage, onComplete)
    local npc = conversation.npc
    local playerContext = conversation.playerContext

    -- Build the enhanced system prompt with context
    local systemPrompt = BuildContextualSystemPrompt(npc, playerContext, conversation)

    -- Build conversation history for API
    local messages = {}

    -- Add conversation history
    for _, msg in ipairs(conversation.conversationHistory) do
        table.insert(messages, msg)
    end

    -- Prepare API request based on provider
    local requestData, headers

    if Config.AI.provider == "anthropic" then
        -- Anthropic Claude API format
        requestData = {
            model = Config.AI.model,
            messages = messages,
            max_tokens = Config.AI.maxTokens,
            temperature = Config.AI.temperature,
            system = systemPrompt
        }

        headers = {
            ["Content-Type"] = "application/json",
            ["x-api-key"] = Config.AI.apiKey,
            ["anthropic-version"] = "2023-06-01"
        }
    else
        -- OpenAI API format - prepend system message
        table.insert(messages, 1, {
            role = "system",
            content = systemPrompt
        })

        requestData = {
            model = Config.AI.model,
            messages = messages,
            max_tokens = Config.AI.maxTokens,
            temperature = Config.AI.temperature
        }

        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. Config.AI.apiKey
        }
    end

    -- Timeout tracking
    local requestId = GetGameTimer()
    local hasResponded = false
    local timeoutTriggered = false

    -- Set up timeout handler
    SetTimeout(GLOBAL_STAGGER.requestTimeoutMs, function()
        if not hasResponded then
            timeoutTriggered = true
            print(("[AI NPCs] Request timeout for player %s"):format(playerId))
            local fallback = GetFallbackResponse(npc, "timeout")
            TriggerClientEvent('ai-npcs:client:receiveMessage', playerId, fallback, npc.id)
            if onComplete then onComplete() end
        end
    end)

    -- Make API request
    PerformHttpRequest(Config.AI.apiUrl, function(statusCode, response, respHeaders)
        -- Ignore if timeout already triggered
        if timeoutTriggered then return end
        hasResponded = true

        if statusCode == 200 then
            local success, data = pcall(json.decode, response)
            local aiResponse = nil

            if success then
                if Config.AI.provider == "anthropic" and data.content and data.content[1] then
                    aiResponse = data.content[1].text
                elseif data.choices and data.choices[1] then
                    aiResponse = data.choices[1].message.content
                end
            end

            if aiResponse then
                -- Clean up response
                aiResponse = CleanAIResponse(aiResponse)

                -- Add AI response to conversation history
                table.insert(conversation.conversationHistory, {
                    role = "assistant",
                    content = aiResponse
                })

                -- Send response to client
                TriggerClientEvent('ai-npcs:client:receiveMessage', playerId, aiResponse, npc.id)

                -- Generate TTS if enabled
                if Config.TTS.enabled and Config.TTS.apiKey ~= "YOUR_ELEVENLABS_KEY_HERE" then
                    GenerateTTS(playerId, aiResponse, npc.voice or Config.TTS.defaultVoice)
                end

                if Config.Debug.printResponses then
                    print(("[AI NPCs] %s says: %s"):format(npc.name, aiResponse:sub(1, 80) .. "..."))
                end
            else
                print("[AI NPCs] Failed to parse AI response")
                print("[AI NPCs] Raw response: " .. tostring(response))
                local fallback = GetFallbackResponse(npc, "parse_error")
                TriggerClientEvent('ai-npcs:client:receiveMessage', playerId, fallback, npc.id)
            end
        elseif statusCode == 429 then
            -- Rate limited by API
            print("[AI NPCs] API rate limit hit (429)")
            local fallback = GetFallbackResponse(npc, "api_error")
            TriggerClientEvent('ai-npcs:client:receiveMessage', playerId, fallback, npc.id)
        else
            print(("[AI NPCs] AI API request failed with status: %s"):format(statusCode))
            print("[AI NPCs] Response: " .. tostring(response))
            local fallback = GetFallbackResponse(npc, "api_error")
            TriggerClientEvent('ai-npcs:client:receiveMessage', playerId, fallback, npc.id)
        end

        if onComplete then onComplete() end
    end, 'POST', json.encode(requestData), headers)
end

-----------------------------------------------------------
-- Build Context-Aware System Prompt (v2.5 Enhanced)
-----------------------------------------------------------
function BuildContextualSystemPrompt(npc, playerContext, conversation)
    local prompt = npc.systemPrompt .. "\n\n"

    local citizenid = playerContext.citizenid

    -- ===========================================
    -- V2.5: NPC MOOD CONTEXT
    -- ===========================================
    local moodContext, moodEffects = "", nil
    if exports['ai-npcs'].BuildMoodContext then
        moodContext, moodEffects = exports['ai-npcs']:BuildMoodContext(npc.id, npc)
        if moodContext and moodContext ~= "" then
            prompt = prompt .. moodContext .. "\n"
        end
    end

    -- ===========================================
    -- V2.5: FACTION TRUST CONTEXT
    -- ===========================================
    if exports['ai-npcs'].BuildFactionContext and citizenid then
        local factionContext = exports['ai-npcs']:BuildFactionContext(npc.id, citizenid, playerContext.name)
        if factionContext and factionContext ~= "" then
            prompt = prompt .. factionContext .. "\n"
        end
    end

    -- ===========================================
    -- V2.5: RUMOR MILL CONTEXT
    -- ===========================================
    if exports['ai-npcs'].BuildRumorContext and citizenid then
        local rumorContext = exports['ai-npcs']:BuildRumorContext(npc.id, citizenid, npc)
        if rumorContext and rumorContext ~= "" then
            prompt = prompt .. rumorContext .. "\n"
        end
    end

    -- ===========================================
    -- V2.5: INTEL CONTEXT (what you can offer)
    -- ===========================================
    if exports['ai-npcs'].BuildIntelContext and citizenid then
        local intelContext = exports['ai-npcs']:BuildIntelContext(npc.id, citizenid)
        if intelContext and intelContext ~= "" then
            prompt = prompt .. intelContext .. "\n"
        end
    end

    -- Add current context section
    prompt = prompt .. "=== CURRENT SITUATION ===\n"

    -- Player info
    prompt = prompt .. ("You are currently talking to: %s\n"):format(playerContext.name)
    prompt = prompt .. ("Their job: %s\n"):format(playerContext.jobLabel)

    -- Trust level affects how open you are
    prompt = prompt .. ("Your relationship with them: %s (Trust: %d/100)\n"):format(
        conversation.trustLevel, conversation.trustValue
    )

    -- Context-specific instructions
    if playerContext.isCop then
        prompt = prompt .. "\n⚠️ WARNING: This person is LAW ENFORCEMENT. "
        local reaction = npc.contextReactions.copReaction
        if reaction == "extremely_suspicious" then
            prompt = prompt .. "Be very evasive. Give vague or misleading answers. Try to end the conversation. Do NOT reveal criminal information.\n"
        elseif reaction == "hostile_dismissive" then
            prompt = prompt .. "Be hostile and dismissive. Refuse to engage. Make it clear you don't talk to cops.\n"
        elseif reaction == "paranoid_shutdown" then
            prompt = prompt .. "Completely shut down. Deny knowing anything about anything illegal. Be boring and unhelpful.\n"
        elseif reaction == "professional_denial" then
            prompt = prompt .. "Maintain your cover story perfectly. Be polite but reveal nothing illegal.\n"
        else
            prompt = prompt .. "Be careful about what you reveal.\n"
        end
    else
        -- Non-cop context modifiers
        if playerContext.hasDrugs then
            prompt = prompt .. "✓ They appear to be carrying drugs. This suggests they're in the game. You can be more open about drug-related topics.\n"
        end

        if playerContext.hasCrimeTools then
            prompt = prompt .. "✓ They have professional tools (lockpicks, thermite, etc). They seem like a serious operator.\n"
        end

        if playerContext.hasWeapons then
            prompt = prompt .. "✓ They're armed. Treat them with appropriate respect/caution.\n"
        end

        if playerContext.cash > 10000 then
            prompt = prompt .. ("✓ They're carrying $%d in cash. They might be willing to pay for information.\n"):format(playerContext.cash)
        elseif playerContext.cash < 500 then
            prompt = prompt .. "✗ They don't seem to have much money on them.\n"
        end

        if playerContext.gang and playerContext.gang ~= "" then
            prompt = prompt .. ("✓ They're affiliated with: %s\n"):format(playerContext.gang)
        end
    end

    -- Trust level behavior
    prompt = prompt .. "\n=== TRUST LEVEL BEHAVIOR ===\n"
    if conversation.trustLevel == "Stranger" then
        prompt = prompt .. "They are a STRANGER. Be cautious. Only share vague rumors or public knowledge. Encourage them to prove themselves or pay for information.\n"
    elseif conversation.trustLevel == "Acquaintance" then
        prompt = prompt .. "They are an ACQUAINTANCE. You've met before. Share basic information if they pay. Don't reveal sensitive details yet.\n"
    elseif conversation.trustLevel == "Trusted" then
        prompt = prompt .. "They are TRUSTED. You've built a relationship. Share detailed information for fair payment. Warn them about dangers.\n"
    elseif conversation.trustLevel == "Inner Circle" then
        prompt = prompt .. "They are INNER CIRCLE. They've proven themselves completely. Share sensitive information freely. Give them the real good stuff.\n"
    end

    -- Payment context
    if conversation.paymentMade > 0 then
        prompt = prompt .. ("\n💰 They have paid you $%d this conversation. Be appropriately grateful and informative.\n"):format(conversation.paymentMade)
    end

    -- Intel request context
    if conversation.requestedIntel then
        prompt = prompt .. ("\n📋 INTEL REQUEST: They're asking about '%s' (tier: %s). Provide appropriate information based on trust and payment.\n"):format(
            conversation.requestedIntel.topic, conversation.requestedIntel.tier
        )
    end

    -- Reminder about format
    prompt = prompt .. "\n=== RESPONSE GUIDELINES ===\n"
    prompt = prompt .. "- Stay in character at all times\n"
    prompt = prompt .. "- Keep responses under 100 words\n"
    prompt = prompt .. "- Use appropriate actions in *asterisks*\n"
    prompt = prompt .. "- If they haven't paid enough for information, hint at needing payment\n"
    prompt = prompt .. "- If they're a cop, stick to your cover story\n"
    prompt = prompt .. "- Reference their trust level naturally in how open you are\n"

    return prompt
end

-----------------------------------------------------------
-- Clean AI Response
-----------------------------------------------------------
function CleanAIResponse(response)
    -- Remove any markdown formatting that might slip through
    response = response:gsub("```", "")
    response = response:gsub("##", "")
    response = response:gsub("**", "")

    -- Trim whitespace
    response = response:match("^%s*(.-)%s*$")

    -- Limit length if too long
    if #response > 500 then
        response = response:sub(1, 497) .. "..."
    end

    return response
end

-----------------------------------------------------------
-- Text-to-Speech Generation (with proper caching)
-----------------------------------------------------------
local audioCache = {}
local cacheSize = 0

-- Create a deterministic cache key from text + voice
local function GetTTSCacheKey(text, voiceId)
    -- Normalize text (lowercase, trim, remove excess whitespace)
    local normalized = text:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    -- Create hash from text + voice
    return GetHashKey(normalized .. "_" .. (voiceId or "default"))
end

function GenerateTTS(playerId, text, voiceId)
    if not Config.TTS.enabled then return end
    if not Config.TTS.apiKey or Config.TTS.apiKey == "YOUR_ELEVENLABS_KEY_HERE" then
        return
    end

    local voice = voiceId or Config.TTS.defaultVoice
    local cacheKey = GetTTSCacheKey(text, voice)

    -- Check cache first - if we have this exact phrase already, just play it
    if Config.TTS.cacheAudio and audioCache[cacheKey] then
        local cachedFile = audioCache[cacheKey]
        TriggerClientEvent('ai-npcs:client:playAudio', playerId, cachedFile)
        if Config.Debug.enabled then
            print(("[AI NPCs] TTS cache hit: %s"):format(cachedFile))
        end
        return
    end

    local requestData = {
        text = text,
        model_id = "eleven_monolingual_v1",
        voice_settings = {
            stability = 0.5,
            similarity_boost = 0.75
        }
    }

    local headers = {
        ["Content-Type"] = "application/json",
        ["xi-api-key"] = Config.TTS.apiKey
    }

    local url = Config.TTS.apiUrl .. voice

    PerformHttpRequest(url, function(statusCode, response, respHeaders)
        if statusCode == 200 then
            local fileName = ("audio_%s.ogg"):format(cacheKey)
            local savePath = "audio/" .. fileName

            -- Save audio file
            local saved = SaveResourceFile(GetCurrentResourceName(), savePath, response, #response)

            if saved then
                -- Cache reference
                if Config.TTS.cacheAudio then
                    audioCache[cacheKey] = fileName
                    cacheSize = cacheSize + 1

                    -- Clean cache if too large
                    if cacheSize > Config.TTS.maxCacheSize then
                        CleanAudioCache()
                    end
                end

                -- Send to client
                TriggerClientEvent('ai-npcs:client:playAudio', playerId, fileName)

                if Config.Debug.enabled then
                    print(("[AI NPCs] Generated TTS audio: %s (cached)"):format(fileName))
                end
            end
        else
            if Config.Debug.enabled then
                print(("[AI NPCs] TTS request failed with status: %s"):format(statusCode))
            end
        end
    end, 'POST', json.encode(requestData), headers)
end

-----------------------------------------------------------
-- Audio Cache Management
-----------------------------------------------------------
function CleanAudioCache()
    local count = 0
    for audioId, fileName in pairs(audioCache) do
        if count >= 10 then break end

        audioCache[audioId] = nil
        cacheSize = cacheSize - 1
        count = count + 1
    end

    if Config.Debug.enabled then
        print(("[AI NPCs] Cleaned %d cached audio files"):format(count))
    end
end

-----------------------------------------------------------
-- ADMIN COMMANDS (Token Bucket Management)
-----------------------------------------------------------
local ADMIN_JOBS = {
    ['admin'] = true,
    ['god'] = true,
    ['developer'] = true,
}

local function IsAdmin(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end

    local job = Player.PlayerData.job.name
    local group = QBCore.Functions.GetPermission(source)

    -- Check job-based admin
    if ADMIN_JOBS[job] then return true end

    -- Check permission group (ace permissions)
    if group == 'admin' or group == 'god' then return true end

    return false
end

-- /ainpc tokens [player_id] - Check a player's token bucket status
RegisterCommand('ainpc', function(source, args, rawCommand)
    if source > 0 and not IsAdmin(source) then
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'Access Denied',
            description = 'Admin only command',
            type = 'error'
        })
        return
    end

    local subcommand = args[1]

    if subcommand == 'tokens' then
        -- Check token status
        local targetId = tonumber(args[2])
        if not targetId then
            -- Show all players with buckets
            local output = "^3[AI NPCs] Token Bucket Status:^7\n"
            local count = 0
            for playerId, bucket in pairs(playerBuckets) do
                local Player = QBCore.Functions.GetPlayer(playerId)
                local name = Player and Player.PlayerData.charinfo.firstname or "Unknown"
                local tokens = GetTokensRemaining(playerId)
                local nextToken = math.ceil(GetTimeUntilNextToken(playerId) / 1000)
                output = output .. ("  ID %d (%s): %d/%d tokens, next in %ds\n"):format(
                    playerId, name, tokens, TOKEN_BUCKET.maxTokens, nextToken
                )
                count = count + 1
            end
            if count == 0 then
                output = output .. "  No active buckets\n"
            end
            print(output)

            if source > 0 then
                TriggerClientEvent('ox_lib:notify', source, {
                    title = 'Token Status',
                    description = count .. ' active player buckets (see console)',
                    type = 'info'
                })
            end
        else
            -- Check specific player
            local tokens = GetTokensRemaining(targetId)
            local nextToken = math.ceil(GetTimeUntilNextToken(targetId) / 1000)
            local pending = pendingRequests[targetId] and "Yes" or "No"

            local msg = ("Player %d: %d/%d tokens, next in %ds, pending: %s"):format(
                targetId, tokens, TOKEN_BUCKET.maxTokens, nextToken, pending
            )
            print("[AI NPCs] " .. msg)

            if source > 0 then
                TriggerClientEvent('ox_lib:notify', source, {
                    title = 'Token Status',
                    description = msg,
                    type = 'info'
                })
            end
        end

    elseif subcommand == 'refill' then
        -- Refill a player's tokens
        local targetId = tonumber(args[2])
        if not targetId then
            if source > 0 then
                TriggerClientEvent('ox_lib:notify', source, {
                    title = 'Usage',
                    description = '/ainpc refill [player_id]',
                    type = 'error'
                })
            else
                print("[AI NPCs] Usage: /ainpc refill [player_id]")
            end
            return
        end

        -- Reset bucket to full
        playerBuckets[targetId] = {
            tokens = TOKEN_BUCKET.maxTokens,
            lastRefill = GetGameTimer()
        }

        local msg = ("Refilled tokens for player %d to %d"):format(targetId, TOKEN_BUCKET.maxTokens)
        print("[AI NPCs] " .. msg)

        if source > 0 then
            TriggerClientEvent('ox_lib:notify', source, {
                title = 'Tokens Refilled',
                description = msg,
                type = 'success'
            })
        end

        -- Notify target player
        TriggerClientEvent('ox_lib:notify', targetId, {
            title = 'AI NPCs',
            description = 'Your conversation limit has been reset',
            type = 'info'
        })

    elseif subcommand == 'refillall' then
        -- Refill all players' tokens
        local count = 0
        for playerId, _ in pairs(playerBuckets) do
            playerBuckets[playerId] = {
                tokens = TOKEN_BUCKET.maxTokens,
                lastRefill = GetGameTimer()
            }
            count = count + 1
        end

        local msg = ("Refilled tokens for %d players"):format(count)
        print("[AI NPCs] " .. msg)

        if source > 0 then
            TriggerClientEvent('ox_lib:notify', source, {
                title = 'All Tokens Refilled',
                description = msg,
                type = 'success'
            })
        end

    elseif subcommand == 'queue' then
        -- Show request queue status
        local output = ("^3[AI NPCs] Queue Status:^7\n")
        output = output .. ("  Queued requests: %d\n"):format(#requestQueue)
        output = output .. ("  Concurrent: %d/%d\n"):format(currentConcurrent, GLOBAL_STAGGER.maxConcurrent)
        output = output .. ("  Processing: %s\n"):format(isProcessingQueue and "Yes" or "No")

        for i, req in ipairs(requestQueue) do
            if i > 5 then
                output = output .. ("  ... and %d more\n"):format(#requestQueue - 5)
                break
            end
            local age = math.floor((GetGameTimer() - req.queuedAt) / 1000)
            output = output .. ("  [%d] Player %d, queued %ds ago\n"):format(i, req.playerId, age)
        end
        print(output)

        if source > 0 then
            TriggerClientEvent('ox_lib:notify', source, {
                title = 'Queue Status',
                description = ('%d queued, %d/%d concurrent'):format(
                    #requestQueue, currentConcurrent, GLOBAL_STAGGER.maxConcurrent
                ),
                type = 'info'
            })
        end

    elseif subcommand == 'debug' then
        -- Toggle debug mode
        Config.Debug.enabled = not Config.Debug.enabled
        local state = Config.Debug.enabled and "ENABLED" or "DISABLED"
        print(("[AI NPCs] Debug mode %s"):format(state))

        if source > 0 then
            TriggerClientEvent('ox_lib:notify', source, {
                title = 'Debug Mode',
                description = state,
                type = Config.Debug.enabled and 'success' or 'info'
            })
        end

    else
        -- Show help
        local help = [[
^3[AI NPCs] Admin Commands:^7
  /ainpc tokens [id]    - Check token bucket status (all or specific player)
  /ainpc refill <id>    - Refill a player's tokens to max
  /ainpc refillall      - Refill all players' tokens
  /ainpc queue          - Show request queue status
  /ainpc debug          - Toggle debug mode
]]
        print(help)

        if source > 0 then
            TriggerClientEvent('ox_lib:notify', source, {
                title = 'AI NPC Commands',
                description = 'See console (F8) for command list',
                type = 'info'
            })
        end
    end
end, false)

-- Export for external admin tools
exports('GetPlayerTokens', GetTokensRemaining)
exports('RefillPlayerTokens', function(playerId)
    playerBuckets[playerId] = {
        tokens = TOKEN_BUCKET.maxTokens,
        lastRefill = GetGameTimer()
    }
    return true
end)
