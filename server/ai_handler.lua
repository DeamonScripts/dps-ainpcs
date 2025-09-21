-- AI Response Generation
function GenerateAIResponse(playerId, conversation, playerMessage)
    local npc = conversation.npc

    -- Build conversation context
    local messages = {
        {
            role = "system",
            content = npc.systemPrompt
        }
    }

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
            system = npc.systemPrompt
        }

        headers = {
            ["Content-Type"] = "application/json",
            ["x-api-key"] = Config.AI.apiKey,
            ["anthropic-version"] = "2023-06-01"
        }
    else
        -- OpenAI API format
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
    PerformHttpRequest(Config.AI.apiUrl, function(statusCode, response, headers)
        if statusCode == 200 then
            local success, data = pcall(json.decode, response)
            local aiResponse = nil

            if success then
                if Config.AI.provider == "anthropic" and data.content and data.content[1] then
                    -- Anthropic Claude response format
                    aiResponse = data.content[1].text
                elseif data.choices and data.choices[1] then
                    -- OpenAI response format
                    aiResponse = data.choices[1].message.content
                end
            end

            if aiResponse then

                -- Add AI response to conversation history
                table.insert(conversation.conversationHistory, {
                    role = "assistant",
                    content = aiResponse
                })

                -- Send response to client
                TriggerClientEvent('ai-npcs:client:receiveMessage', playerId, aiResponse, npc.id)

                -- Generate TTS if enabled
                if Config.TTS.apiKey and Config.TTS.apiKey ~= "YOUR_ELEVENLABS_KEY_HERE" then
                    GenerateTTS(playerId, aiResponse, npc.voice)
                end

                print(("[AI NPCs] Generated response for %s: %s"):format(npc.name, aiResponse:sub(1, 50) .. "..."))
            else
                print("[AI NPCs] Failed to parse AI response")
                TriggerClientEvent('ai-npcs:client:receiveMessage', playerId, "Sorry, I lost my train of thought...", npc.id)
            end
        else
            print(("[AI NPCs] AI API request failed with status: %s"):format(statusCode))
            TriggerClientEvent('ai-npcs:client:receiveMessage', playerId, "Hmm, my mind's a bit foggy right now...", npc.id)
        end
    end, 'POST', json.encode(requestData), headers)
end

-- Text-to-Speech Generation
function GenerateTTS(playerId, text, voiceId, audioId)
    if not Config.TTS.apiKey or Config.TTS.apiKey == "YOUR_ELEVENLABS_KEY_HERE" then
        return -- TTS not configured
    end

    local requestData = {
        text = text,
        model_id = "eleven_monolingual_v1",
        voice_settings = {
            stability = 0.5,
            similarity_boost = 0.5
        }
    }

    local headers = {
        ["Content-Type"] = "application/json",
        ["xi-api-key"] = Config.TTS.apiKey
    }

    local url = Config.TTS.apiUrl .. voiceId

    PerformHttpRequest(url, function(statusCode, response, headers)
        if statusCode == 200 then
            -- Save audio file
            local fileName = ("audio_%s.ogg"):format(audioId or GetHashKey(text))
            local filePath = GetResourcePath(GetCurrentResourceName()) .. "/audio/" .. fileName

            -- Save binary audio data (this is simplified - in practice you'd need proper binary handling)
            SaveResourceFile(GetCurrentResourceName(), "audio/" .. fileName, response, #response)

            -- Cache the audio
            if audioId and Config.TTS.cacheAudio then
                audioCache[audioId] = fileName
                cacheSize = cacheSize + 1

                -- Clean cache if too large
                if cacheSize > Config.TTS.maxCacheSize then
                    CleanAudioCache()
                end
            end

            -- Send audio to client
            TriggerClientEvent('ai-npcs:client:playAudio', playerId, fileName)

            print(("[AI NPCs] Generated TTS audio: %s"):format(fileName))
        else
            print(("[AI NPCs] TTS request failed with status: %s"):format(statusCode))
        end
    end, 'POST', json.encode(requestData), headers)
end

-- Clean oldest cached audio files
function CleanAudioCache()
    local count = 0
    for audioId, fileName in pairs(audioCache) do
        if count >= 10 then break end -- Remove 10 oldest

        audioCache[audioId] = nil
        cacheSize = cacheSize - 1
        count = count + 1

        -- Delete file (optional)
        -- os.remove(GetResourcePath(GetCurrentResourceName()) .. "/audio/" .. fileName)
    end

    print(("[AI NPCs] Cleaned %d cached audio files"):format(count))
end