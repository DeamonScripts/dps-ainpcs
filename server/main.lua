local QBCore = exports['qb-core']:GetCoreObject()

-- Audio cache to store generated TTS files
local audioCache = {}
local cacheSize = 0

-- Conversation tracking
local activeConversations = {}

-- Startup
CreateThread(function()
    print("[AI NPCs] Server started - AI conversation system loaded")
end)

-- Clean old conversations
CreateThread(function()
    while true do
        Wait(60000) -- Check every minute
        local currentTime = GetGameTimer()

        for playerId, conversation in pairs(activeConversations) do
            if currentTime - conversation.lastActivity > 300000 then -- 5 minutes timeout
                activeConversations[playerId] = nil
                print(("[AI NPCs] Cleaned expired conversation for player %s"):format(playerId))
            end
        end
    end
end)

-- Handle NPC interaction start
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

    -- Initialize conversation
    activeConversations[src] = {
        npcId = npcId,
        npc = npc,
        messageCount = 0,
        lastActivity = GetGameTimer(),
        conversationHistory = {}
    }

    -- Send greeting
    TriggerClientEvent('ai-npcs:client:receiveMessage', src, npc.personality.greeting, npc.id)

    print(("[AI NPCs] Started conversation between player %s and %s"):format(src, npc.name))
end)

-- Handle player message to NPC
RegisterNetEvent('ai-npcs:server:sendMessage', function(message)
    local src = source
    local conversation = activeConversations[src]

    if not conversation then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'Error',
            description = 'No active conversation found',
            type = 'error'
        })
        return
    end

    -- Update activity
    conversation.lastActivity = GetGameTimer()
    conversation.messageCount = conversation.messageCount + 1

    -- Check conversation limits
    if conversation.messageCount > Config.Interaction.maxConversationLength then
        TriggerClientEvent('ai-npcs:client:endConversation', src, "I gotta go, too much attention...")
        activeConversations[src] = nil
        return
    end

    -- Add to conversation history
    table.insert(conversation.conversationHistory, {
        role = "user",
        content = message
    })

    -- Generate AI response
    GenerateAIResponse(src, conversation, message)
end)

-- End conversation
RegisterNetEvent('ai-npcs:server:endConversation', function()
    local src = source
    activeConversations[src] = nil
    print(("[AI NPCs] Ended conversation for player %s"):format(src))
end)

-- Get audio file (cached or generate new)
RegisterNetEvent('ai-npcs:server:getAudio', function(text, voiceId)
    local src = source
    local audioId = GetAudioId(text, voiceId)

    if audioCache[audioId] then
        -- Send cached audio
        TriggerClientEvent('ai-npcs:client:playAudio', src, audioCache[audioId])
    else
        -- Generate new audio
        GenerateTTS(src, text, voiceId, audioId)
    end
end)

-- Helper function to create audio ID
function GetAudioId(text, voiceId)
    return GetHashKey(text .. voiceId)
end