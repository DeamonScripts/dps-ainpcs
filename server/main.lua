local QBCore = exports['qb-core']:GetCoreObject()

-- Data stores
local activeConversations = {}
local playerTrust = {}        -- { [identifier] = { [trustCategory] = { [npcId] = trustLevel } } }
local intelCooldowns = {}     -- { [identifier] = { [topic] = lastAccessTime } }
local audioCache = {}
local cacheSize = 0

-----------------------------------------------------------
-- STARTUP
-----------------------------------------------------------
CreateThread(function()
    print("^2[AI NPCs]^7 Server initialized - Advanced conversation system loaded")
    print("^2[AI NPCs]^7 Trust system: " .. (Config.Trust.enabled and "ENABLED" or "DISABLED"))
    print("^2[AI NPCs]^7 Player context: ENABLED")
    LoadTrustData()
end)

-----------------------------------------------------------
-- TRUST SYSTEM
-----------------------------------------------------------
function LoadTrustData()
    -- Load from database if you have one, otherwise starts fresh
    -- Example: MySQL query to load trust data
    -- For now, we keep it in memory (resets on restart)
    print("[AI NPCs] Trust data initialized (in-memory)")
end

function SaveTrustData()
    -- Save to database
    -- Example: MySQL query to save trust data
end

function GetPlayerTrust(identifier, trustCategory, npcId)
    if not playerTrust[identifier] then return 0 end
    if not playerTrust[identifier][trustCategory] then return 0 end
    if not playerTrust[identifier][trustCategory][npcId] then return 0 end
    return playerTrust[identifier][trustCategory][npcId]
end

function AddPlayerTrust(identifier, trustCategory, npcId, amount)
    if not playerTrust[identifier] then
        playerTrust[identifier] = {}
    end
    if not playerTrust[identifier][trustCategory] then
        playerTrust[identifier][trustCategory] = {}
    end
    if not playerTrust[identifier][trustCategory][npcId] then
        playerTrust[identifier][trustCategory][npcId] = 0
    end

    local current = playerTrust[identifier][trustCategory][npcId]
    playerTrust[identifier][trustCategory][npcId] = math.min(100, current + amount)

    if Config.Debug.enabled then
        print(("[AI NPCs] Trust updated: %s -> %s (+%d) = %d"):format(
            identifier, npcId, amount, playerTrust[identifier][trustCategory][npcId]
        ))
    end
end

function GetTrustLevel(trustValue)
    for _, level in ipairs(Config.Trust.levels) do
        if trustValue >= level.minTrust and trustValue <= level.maxTrust then
            return level.name
        end
    end
    return "Stranger"
end

-----------------------------------------------------------
-- PLAYER CONTEXT
-----------------------------------------------------------
function GetPlayerContext(playerId)
    local Player = QBCore.Functions.GetPlayer(playerId)
    if not Player then return nil end

    local context = {
        name = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname,
        job = Player.PlayerData.job.name,
        jobLabel = Player.PlayerData.job.label,
        jobGrade = Player.PlayerData.job.grade.level,
        isCop = false,
        cash = Player.PlayerData.money.cash,
        hasDrugs = false,
        hasWeapons = false,
        hasCrimeTools = false,
        hasValuables = false,
        gang = Player.PlayerData.gang and Player.PlayerData.gang.name or nil,
        metadata = Player.PlayerData.metadata or {}
    }

    -- Check if cop
    for _, copJob in ipairs(Config.PlayerContext.suspiciousJobs) do
        if context.job == copJob then
            context.isCop = true
            break
        end
    end

    -- Check inventory for special items
    local items = Player.PlayerData.items
    if items then
        for _, item in pairs(items) do
            if item and item.name then
                -- Check drugs
                for _, drug in ipairs(Config.PlayerContext.specialItems.drugs) do
                    if item.name == drug then
                        context.hasDrugs = true
                        break
                    end
                end
                -- Check weapons
                for _, weapon in ipairs(Config.PlayerContext.specialItems.weapons) do
                    if item.name == weapon then
                        context.hasWeapons = true
                        break
                    end
                end
                -- Check crime tools
                for _, tool in ipairs(Config.PlayerContext.specialItems.crimeTools) do
                    if item.name == tool then
                        context.hasCrimeTools = true
                        break
                    end
                end
                -- Check valuables
                for _, valuable in ipairs(Config.PlayerContext.specialItems.valuables) do
                    if item.name == valuable then
                        context.hasValuables = true
                        break
                    end
                end
            end
        end
    end

    if Config.Debug.printPlayerContext then
        print(("[AI NPCs] Player context for %s:"):format(playerId))
        print(json.encode(context, { indent = true }))
    end

    return context
end

-----------------------------------------------------------
-- INTEL SYSTEM
-----------------------------------------------------------
function CanAccessIntel(identifier, topic, tier)
    if not intelCooldowns[identifier] then return true end
    if not intelCooldowns[identifier][topic] then return true end

    local cooldown = Config.Intel.cooldowns[tier] or 600000
    local lastAccess = intelCooldowns[identifier][topic]
    local now = GetGameTimer()

    return (now - lastAccess) >= cooldown
end

function RecordIntelAccess(identifier, topic)
    if not intelCooldowns[identifier] then
        intelCooldowns[identifier] = {}
    end
    intelCooldowns[identifier][topic] = GetGameTimer()
end

function GetIntelPrice(tier)
    local priceRange = Config.Intel.prices[tier]
    if not priceRange then return 0 end
    return math.random(priceRange.min, priceRange.max)
end

-----------------------------------------------------------
-- CONVERSATION MANAGEMENT
-----------------------------------------------------------
RegisterNetEvent('ai-npcs:server:startConversation', function(npcId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- Find NPC config
    local npc = nil
    for _, npcData in pairs(Config.NPCs) do
        if npcData.id == npcId then
            npc = npcData
            break
        end
    end

    if not npc then
        print(("[AI NPCs] NPC not found: %s"):format(npcId))
        return
    end

    -- Get player context and trust
    local identifier = Player.PlayerData.citizenid
    local playerContext = GetPlayerContext(src)
    local trustValue = GetPlayerTrust(identifier, npc.trustCategory, npcId)
    local trustLevel = GetTrustLevel(trustValue)

    -- Initialize conversation
    activeConversations[src] = {
        npcId = npcId,
        npc = npc,
        messageCount = 0,
        lastActivity = GetGameTimer(),
        conversationHistory = {},
        playerContext = playerContext,
        identifier = identifier,
        trustValue = trustValue,
        trustLevel = trustLevel,
        paymentMade = 0
    }

    -- Build contextual greeting
    local greeting = BuildContextualGreeting(npc, playerContext, trustLevel)

    -- Send greeting
    TriggerClientEvent('ai-npcs:client:receiveMessage', src, greeting, npc.id)

    -- Add trust for visiting
    if Config.Trust.enabled then
        AddPlayerTrust(identifier, npc.trustCategory, npcId, Config.Trust.earnRates.repeatVisit)
    end

    print(("[AI NPCs] Started conversation: Player %s (%s) with %s (Trust: %s/%d)"):format(
        src, trustLevel, npc.name, trustLevel, trustValue
    ))
end)

function BuildContextualGreeting(npc, playerContext, trustLevel)
    local greeting = npc.personality.greeting

    -- Modify greeting based on context
    if playerContext.isCop then
        local reaction = npc.contextReactions.copReaction
        if reaction == "extremely_suspicious" then
            greeting = "*eyes you warily* ...Something I can help you with, officer?"
        elseif reaction == "hostile_dismissive" then
            greeting = "*turns away* I got nothing to say to you, pig."
        elseif reaction == "paranoid_shutdown" then
            greeting = "*becomes very still* I think you have the wrong person."
        elseif reaction == "professional_denial" then
            greeting = "Good day, officer. I'm just a simple antiques dealer. How may I help?"
        end
    elseif trustLevel == "Inner Circle" then
        greeting = "*nods with respect* Good to see you again, friend. What do you need?"
    elseif trustLevel == "Trusted" then
        greeting = "*relaxes slightly* Ah, you're back. What's on your mind?"
    end

    return greeting
end

RegisterNetEvent('ai-npcs:server:sendMessage', function(message, paymentOffer)
    local src = source
    local conversation = activeConversations[src]

    if not conversation then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'Error',
            description = 'No active conversation',
            type = 'error'
        })
        return
    end

    -- Handle payment
    if paymentOffer and paymentOffer > 0 then
        local Player = QBCore.Functions.GetPlayer(src)
        if Player and Player.PlayerData.money.cash >= paymentOffer then
            Player.Functions.RemoveMoney('cash', paymentOffer, 'npc-intel-payment')
            conversation.paymentMade = conversation.paymentMade + paymentOffer
            AddPlayerTrust(conversation.identifier, conversation.npc.trustCategory,
                conversation.npcId, Config.Trust.earnRates.payment)

            TriggerClientEvent('ox_lib:notify', src, {
                title = conversation.npc.name,
                description = ("Received $%d"):format(paymentOffer),
                type = 'success'
            })
        end
    end

    -- Update activity
    conversation.lastActivity = GetGameTimer()
    conversation.messageCount = conversation.messageCount + 1

    -- Check conversation limits
    if conversation.messageCount > Config.Interaction.maxConversationLength then
        local endMsg = "I've said enough. Come back another time..."
        TriggerClientEvent('ai-npcs:client:endConversation', src, endMsg)
        activeConversations[src] = nil
        return
    end

    -- Add to conversation history
    table.insert(conversation.conversationHistory, {
        role = "user",
        content = message
    })

    -- Generate AI response with full context
    GenerateAIResponse(src, conversation, message)
end)

RegisterNetEvent('ai-npcs:server:endConversation', function()
    local src = source
    local conversation = activeConversations[src]

    if conversation then
        -- Add trust for completing conversation
        if Config.Trust.enabled and conversation.messageCount >= 3 then
            AddPlayerTrust(conversation.identifier, conversation.npc.trustCategory,
                conversation.npcId, Config.Trust.earnRates.conversation)
        end
    end

    activeConversations[src] = nil
    print(("[AI NPCs] Ended conversation for player %s"):format(src))
end)

-----------------------------------------------------------
-- INTEL REQUEST HANDLING
-----------------------------------------------------------
RegisterNetEvent('ai-npcs:server:requestIntel', function(topic, tier)
    local src = source
    local conversation = activeConversations[src]

    if not conversation then return end

    local npc = conversation.npc
    local identifier = conversation.identifier

    -- Check trust requirement
    local trustRequired = Config.Intel.trustRequirements[tier] or 0
    if conversation.trustValue < trustRequired then
        TriggerClientEvent('ai-npcs:client:receiveMessage', src,
            "*shakes head* I don't know you well enough to talk about that...", npc.id)
        return
    end

    -- Check cooldown
    if not CanAccessIntel(identifier, topic, tier) then
        TriggerClientEvent('ai-npcs:client:receiveMessage', src,
            "I already told you what I know about that. Come back later.", npc.id)
        return
    end

    -- Get price
    local price = GetIntelPrice(tier)

    -- Check if player paid enough
    if tier ~= "rumors" and conversation.paymentMade < price then
        TriggerClientEvent('ai-npcs:client:receiveMessage', src,
            ("*rubs fingers together* That kind of information costs money... About $%d."):format(price), npc.id)
        TriggerClientEvent('ai-npcs:client:showPaymentPrompt', src, price, topic, tier)
        return
    end

    -- Record access
    RecordIntelAccess(identifier, topic)

    -- Add to conversation for AI to reference
    conversation.requestedIntel = { topic = topic, tier = tier }
end)

-----------------------------------------------------------
-- CONVERSATION CLEANUP
-----------------------------------------------------------
CreateThread(function()
    while true do
        Wait(60000)
        local currentTime = GetGameTimer()

        for playerId, conversation in pairs(activeConversations) do
            if currentTime - conversation.lastActivity > Config.Interaction.idleTimeout then
                TriggerClientEvent('ai-npcs:client:endConversation', playerId,
                    "Looks like you've got other things on your mind... We'll talk later.")
                activeConversations[playerId] = nil
                print(("[AI NPCs] Auto-ended idle conversation for player %s"):format(playerId))
            end
        end
    end
end)

-----------------------------------------------------------
-- TRUST DECAY (Optional - runs daily)
-----------------------------------------------------------
if Config.Trust.enabled then
    CreateThread(function()
        while true do
            Wait(Config.Trust.decayCheckInterval)

            for identifier, categories in pairs(playerTrust) do
                for category, npcs in pairs(categories) do
                    for npcId, trust in pairs(npcs) do
                        -- Decay trust over time
                        local newTrust = math.max(0, trust - Config.Trust.decayRate)
                        playerTrust[identifier][category][npcId] = newTrust
                    end
                end
            end

            print("[AI NPCs] Applied trust decay")
            SaveTrustData()
        end
    end)
end

-----------------------------------------------------------
-- AUDIO CACHE
-----------------------------------------------------------
RegisterNetEvent('ai-npcs:server:getAudio', function(text, voiceId)
    local src = source
    local audioId = GetHashKey(text .. voiceId)

    if audioCache[audioId] then
        TriggerClientEvent('ai-npcs:client:playAudio', src, audioCache[audioId])
    else
        GenerateTTS(src, text, voiceId, audioId)
    end
end)

-----------------------------------------------------------
-- EXPORTS FOR OTHER RESOURCES
-----------------------------------------------------------
exports('GetPlayerTrustWithNPC', function(playerId, npcId)
    local Player = QBCore.Functions.GetPlayer(playerId)
    if not Player then return 0 end

    local identifier = Player.PlayerData.citizenid
    for _, npc in pairs(Config.NPCs) do
        if npc.id == npcId then
            return GetPlayerTrust(identifier, npc.trustCategory, npcId)
        end
    end
    return 0
end)

exports('AddPlayerTrustWithNPC', function(playerId, npcId, amount)
    local Player = QBCore.Functions.GetPlayer(playerId)
    if not Player then return false end

    local identifier = Player.PlayerData.citizenid
    for _, npc in pairs(Config.NPCs) do
        if npc.id == npcId then
            AddPlayerTrust(identifier, npc.trustCategory, npcId, amount)
            return true
        end
    end
    return false
end)
