local QBCore = exports['qb-core']:GetCoreObject()
local lib = require 'ox_lib'

-- Local variables
local spawnedNPCs = {}
local activeConversation = nil
local conversationCooldown = false

-- Initialize NPCs on resource start
CreateThread(function()
    while not QBCore do
        Wait(100)
    end

    SpawnNPCs()
    print("[AI NPCs] Client initialized")
end)

-- Spawn all configured NPCs
function SpawnNPCs()
    for _, npcData in pairs(Config.NPCs) do
        CreateNPC(npcData)
    end
end

-- Create individual NPC
function CreateNPC(npcData)
    RequestModel(npcData.model)
    while not HasModelLoaded(npcData.model) do
        Wait(1)
    end

    local npc = CreatePed(4, npcData.model, npcData.coords.x, npcData.coords.y, npcData.coords.z, npcData.coords.w, false, true)

    -- Configure NPC
    FreezeEntityPosition(npc, true)
    SetEntityInvincible(npc, true)
    SetPedFleeAttributes(npc, 0, 0)
    SetPedDiesWhenInjured(npc, false)
    SetPedCanPlayAmbientAnims(npc, true)
    SetPedCanRagdollFromPlayerImpact(npc, false)
    SetEntityCanBeDamaged(npc, false)
    SetPedCanBeTargetted(npc, false)

    -- Add to spawned NPCs
    spawnedNPCs[npcData.id] = {
        entity = npc,
        data = npcData
    }

    -- Add ox_target interaction
    exports.ox_target:addLocalEntity(npc, {
        {
            name = "talk_to_" .. npcData.id,
            label = "Talk to " .. npcData.name,
            icon = "fas fa-comments",
            distance = Config.Interaction.distance,
            onSelect = function()
                StartConversation(npcData.id)
            end
        }
    })

    print(("[AI NPCs] Spawned NPC: %s at %s"):format(npcData.name, npcData.coords))
end

-- Start conversation with NPC
function StartConversation(npcId)
    if activeConversation then
        lib.notify({
            title = 'Conversation',
            description = 'You are already talking to someone',
            type = 'error'
        })
        return
    end

    if conversationCooldown then
        lib.notify({
            title = 'Conversation',
            description = 'Wait a moment before starting another conversation',
            type = 'error'
        })
        return
    end

    local npcData = spawnedNPCs[npcId]
    if not npcData then return end

    activeConversation = {
        npcId = npcId,
        npc = npcData.data
    }

    -- Start conversation on server
    TriggerServerEvent('ai-npcs:server:startConversation', npcId)

    -- Open conversation UI
    OpenConversationUI(npcData.data)

    print(("[AI NPCs] Started conversation with %s"):format(npcData.data.name))
end

-- Open conversation UI
function OpenConversationUI(npcData)
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = "openConversation",
        npcName = npcData.name,
        npcRole = npcData.role
    })
end

-- Close conversation
function EndConversation(reason)
    if not activeConversation then return end

    SetNuiFocus(false, false)
    SendNUIMessage({
        action = "closeConversation"
    })

    if reason then
        lib.notify({
            title = 'Conversation Ended',
            description = reason,
            type = 'info'
        })
    end

    TriggerServerEvent('ai-npcs:server:endConversation')
    activeConversation = nil

    -- Set cooldown
    conversationCooldown = true
    SetTimeout(Config.Interaction.cooldown, function()
        conversationCooldown = false
    end)

    print("[AI NPCs] Conversation ended")
end

-- NUI Callbacks
RegisterNUICallback('sendMessage', function(data, cb)
    if not activeConversation then
        cb('error')
        return
    end

    TriggerServerEvent('ai-npcs:server:sendMessage', data.message)
    cb('ok')
end)

RegisterNUICallback('endConversation', function(data, cb)
    EndConversation()
    cb('ok')
end)

RegisterNUICallback('closeUI', function(data, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

-- Server events
RegisterNetEvent('ai-npcs:client:receiveMessage', function(message, npcId)
    if not activeConversation or activeConversation.npcId ~= npcId then return end

    SendNUIMessage({
        action = "receiveMessage",
        message = message,
        npcName = activeConversation.npc.name
    })

    -- Show subtitle if enabled
    if Config.Interaction.showSubtitles then
        exports['ox_lib']:notify({
            title = activeConversation.npc.name,
            description = message,
            type = 'info',
            duration = 5000
        })
    end
end)

RegisterNetEvent('ai-npcs:client:playAudio', function(audioFile)
    if not activeConversation then return end

    -- Play audio with native FiveM audio system
    if Config.Audio.audioEnabled then
        local npc = spawnedNPCs[activeConversation.npcId]
        if npc and npc.entity then
            -- Get NPC position for positional audio
            local npcCoords = GetEntityCoords(npc.entity)

            -- Play sound from entity position
            -- Note: Audio files need to be properly formatted and loaded
            -- This uses FiveM's native audio system
            PlaySoundFromCoord(-1, "SELECT", npcCoords.x, npcCoords.y, npcCoords.z, "HUD_FRONTEND_DEFAULT_SOUNDSET", false, Config.Audio.range, false)

            print(("[AI NPCs] Playing TTS audio: %s from %s"):format(audioFile, activeConversation.npc.name))

            -- Alternative: Use NUI audio if files are accessible via HTTP
            -- SendNUIMessage({
            --     action = "playAudio",
            --     audioFile = audioFile,
            --     volume = Config.Audio.volume
            -- })
        end
    end
end)

RegisterNetEvent('ai-npcs:client:endConversation', function(reason)
    EndConversation(reason)
end)

-- Cleanup on resource stop
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    -- Remove all NPCs
    for npcId, npcData in pairs(spawnedNPCs) do
        if DoesEntityExist(npcData.entity) then
            DeleteEntity(npcData.entity)
        end
    end

    -- Close any active conversation
    if activeConversation then
        EndConversation()
    end

    print("[AI NPCs] Cleaned up NPCs")
end)