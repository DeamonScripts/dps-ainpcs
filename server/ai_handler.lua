-----------------------------------------------------------
-- AI Response Generation with Full Context
-----------------------------------------------------------
function GenerateAIResponse(playerId, conversation, playerMessage)
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

    -- Make API request
    PerformHttpRequest(Config.AI.apiUrl, function(statusCode, response, respHeaders)
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
                TriggerClientEvent('ai-npcs:client:receiveMessage', playerId,
                    "*mutters* Sorry, lost my train of thought...", npc.id)
            end
        else
            print(("[AI NPCs] AI API request failed with status: %s"):format(statusCode))
            print("[AI NPCs] Response: " .. tostring(response))
            TriggerClientEvent('ai-npcs:client:receiveMessage', playerId,
                "*looks distracted* Give me a second...", npc.id)
        end
    end, 'POST', json.encode(requestData), headers)
end

-----------------------------------------------------------
-- Build Context-Aware System Prompt
-----------------------------------------------------------
function BuildContextualSystemPrompt(npc, playerContext, conversation)
    local prompt = npc.systemPrompt .. "\n\n"

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
-- Text-to-Speech Generation
-----------------------------------------------------------
function GenerateTTS(playerId, text, voiceId, audioId)
    if not Config.TTS.enabled then return end
    if not Config.TTS.apiKey or Config.TTS.apiKey == "YOUR_ELEVENLABS_KEY_HERE" then
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

    local url = Config.TTS.apiUrl .. (voiceId or Config.TTS.defaultVoice)

    PerformHttpRequest(url, function(statusCode, response, respHeaders)
        if statusCode == 200 then
            local fileName = ("audio_%s.ogg"):format(audioId or GetHashKey(text .. os.time()))
            local savePath = "audio/" .. fileName

            -- Save audio file
            local saved = SaveResourceFile(GetCurrentResourceName(), savePath, response, #response)

            if saved then
                -- Cache reference
                if audioId and Config.TTS.cacheAudio then
                    audioCache[audioId] = fileName
                    cacheSize = cacheSize + 1

                    -- Clean cache if too large
                    if cacheSize > Config.TTS.maxCacheSize then
                        CleanAudioCache()
                    end
                end

                -- Send to client
                TriggerClientEvent('ai-npcs:client:playAudio', playerId, fileName)

                if Config.Debug.enabled then
                    print(("[AI NPCs] Generated TTS audio: %s"):format(fileName))
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
