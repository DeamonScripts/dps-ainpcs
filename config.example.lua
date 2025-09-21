Config = {}

-- AI API Configuration
Config.AI = {
    provider = "anthropic", -- "openai" or "anthropic"
    apiUrl = "https://api.anthropic.com/v1/messages",
    apiKey = "YOUR_ANTHROPIC_API_KEY_HERE", -- Get from https://console.anthropic.com/
    model = "claude-3-haiku-20240307", -- Fast and cost-effective
    maxTokens = 150,
    temperature = 0.8
}

-- TTS Configuration
Config.TTS = {
    provider = "elevenlabs", -- "elevenlabs" or "azure"
    apiUrl = "https://api.elevenlabs.io/v1/text-to-speech/",
    apiKey = "YOUR_ELEVENLABS_KEY_HERE", -- Get from https://elevenlabs.io/
    voiceId = "21m00Tcm4TlvDq8ikWAM", -- Default voice (Rachel - conversational)
    cacheAudio = true,
    maxCacheSize = 100 -- Max cached audio files
}

-- NPC Definitions
Config.NPCs = {
    {
        id = "street_informant_01",
        name = "Sketchy Mike",
        model = "a_m_m_tramp_01",
        coords = vector4(1982.21, 3053.65, 47.22, 240.0), -- Yellow Jack Inn area
        role = "street_informant",
        voice = "21m00Tcm4TlvDq8ikWAM", -- ElevenLabs voice ID
        personality = {
            type = "Street Informant",
            traits = "Paranoid, well-informed about local crime, speaks in whispers, knows drug dealers and suppliers",
            knowledge = "Drug locations, supplier contacts, police patrol patterns, territory disputes",
            greeting = "You looking for something specific, or just browsing?"
        },
        systemPrompt = [[You are Sketchy Mike, a street informant in Los Santos. You're paranoid but well-connected to the criminal underworld. You know about:
- Drug lab locations and suppliers
- Who's selling what drugs and where
- Police patrol schedules and raid warnings
- Territory disputes between gangs
- How to get started in drug dealing

You speak in a hushed, paranoid tone. You're helpful but cautious. Keep responses under 100 words. You're always looking over your shoulder and speak in street slang.]]
    }
}

-- Interaction Settings
Config.Interaction = {
    distance = 3.0, -- How close player needs to be
    cooldown = 2000, -- Cooldown between messages (ms)
    maxConversationLength = 10, -- Max back-and-forth exchanges
    showSubtitles = true,
    audioEnabled = true
}

-- Audio Settings
Config.Audio = {
    volume = 0.7,
    range = 15.0, -- Audio range in game units
    enablePositional = true -- 3D positional audio
}