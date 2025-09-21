# AI NPCs - Conversational AI System for FiveM

A complete AI-powered NPC conversation system that allows players to have dynamic, contextual conversations with NPCs using OpenAI GPT-4 and ElevenLabs Text-to-Speech.

## Features

- **Dynamic AI Conversations**: NPCs respond intelligently based on their role and personality
- **Text-to-Speech Audio**: Realistic voice synthesis for immersive conversations
- **Contextual Awareness**: NPCs remember conversation history and respond appropriately
- **Role-Based Personalities**: Each NPC has specific knowledge and conversation focus
- **Modern UI**: Clean, responsive conversation interface
- **Audio Caching**: Efficient TTS caching to reduce API costs
- **ox_target Integration**: Seamless interaction system

## Installation

1. **Add API Keys**: Edit `config.lua` and add your API keys:
   ```lua
   Config.AI.apiKey = "your_openai_api_key_here"
   Config.TTS.apiKey = "your_elevenlabs_api_key_here"
   ```

2. **Configure NPCs**: Modify `config.lua` to set NPC locations and personalities

3. **Add to server.cfg**: Add `ensure ai-npcs` to your server configuration

4. **Restart Server**: Restart your FiveM server to load the resource

## API Setup

### OpenAI API
1. Visit https://platform.openai.com/api-keys
2. Create a new API key
3. Add it to `Config.AI.apiKey` in config.lua

### ElevenLabs API (Optional for TTS)
1. Visit https://elevenlabs.io/app/speech-synthesis
2. Create account and get API key
3. Add it to `Config.TTS.apiKey` in config.lua
4. Copy voice IDs from your ElevenLabs account

## Configuration

### Adding New NPCs

Add new NPCs to the `Config.NPCs` table in config.lua:

```lua
{
    id = "unique_npc_id",
    name = "NPC Display Name",
    model = "game_ped_model",
    coords = vector4(x, y, z, heading),
    role = "npc_role_type",
    voice = "elevenlabs_voice_id",
    personality = {
        type = "Character Type",
        traits = "Personality description",
        knowledge = "What they know about",
        greeting = "Initial greeting message"
    },
    systemPrompt = "Detailed AI system prompt for this character"
}
```

### Conversation Settings

Adjust conversation behavior in config.lua:
- `maxConversationLength`: Maximum exchanges per conversation
- `cooldown`: Time between conversations (ms)
- `distance`: Interaction distance
- `audioEnabled`: Enable/disable TTS audio

## Usage

1. **Approach an NPC**: Walk close to a configured NPC
2. **Start Conversation**: Use ox_target to select "Talk to [NPC Name]"
3. **Chat**: Type messages and receive AI-generated responses
4. **End**: Click "End Conversation" or press Escape

## NPC Roles

### Street Informant
- **Knowledge**: Drug locations, suppliers, police activity
- **Use Cases**: Criminal information, territory intel
- **Location**: Bars, alleys, street corners

### Career Counselor
- **Knowledge**: Job opportunities, career advancement
- **Use Cases**: Legitimate employment guidance
- **Location**: Business districts, offices

### Travel Agent
- **Knowledge**: Flights, destinations, travel planning
- **Use Cases**: Booking trips, tourism information
- **Location**: Airport, travel offices

## Technical Details

### System Architecture
```
Player Input → Client → Server → AI API → TTS API → Audio Cache → Client Playback
```

### Audio System
- Generates OGG audio files from AI responses
- Caches audio to reduce API calls
- Supports positional 3D audio
- Automatic cleanup of old cached files

### Performance
- Conversation timeouts prevent memory leaks
- Audio cache limits prevent storage bloat
- Efficient HTTP request handling
- Client-side UI optimization

## Troubleshooting

### NPCs Not Spawning
- Check console for errors
- Verify NPC coordinates are valid
- Ensure ped models exist

### AI Not Responding
- Verify OpenAI API key is valid
- Check server console for HTTP errors
- Ensure internet connectivity

### Audio Issues
- Verify ElevenLabs API key
- Check voice IDs are correct
- Ensure audio directory exists and is writable

### Performance Issues
- Reduce `maxConversationLength`
- Increase conversation `cooldown`
- Lower `maxCacheSize` for audio

## API Costs

### OpenAI GPT-4
- ~$0.03 per 1k tokens
- Average conversation: ~500 tokens
- Cost per conversation: ~$0.015

### ElevenLabs TTS
- $0.30 per 1k characters
- Average response: ~100 characters
- Cost per response: ~$0.03

### Cost Optimization
- Enable audio caching
- Set reasonable conversation limits
- Use GPT-3.5-turbo for lower costs

## Support

For support and updates, contact the development team or check the server documentation.

## Version History

- v1.0.0 - Initial release with basic AI conversation system
- Planned: Multi-language support, custom voice training, advanced context awareness
