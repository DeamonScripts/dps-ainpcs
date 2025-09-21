fx_version 'cerulean'
game 'gta5'
version '1.0.0'

shared_scripts {
    'config.lua'
}

client_scripts {
    'client/main.lua',
    'client/ui.lua'
}

server_scripts {
    'server/main.lua',
    'server/ai_handler.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
    'audio/*.ogg'
}

lua54 'yes'

dependencies {
    'ox_lib',
    'ox_target',
    'qb-core'
}