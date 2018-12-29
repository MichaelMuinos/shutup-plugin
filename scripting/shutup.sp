#include <sourcemod>

#define PLUGIN_VERSION "0.0.1"

public Plugin myinfo = {
    name = "Shutup Plugin",
    author = "Michael Muinos",
    description = "Ability to Perma-mute and Perma-gag a player.",
    version = PLUGIN_VERSION,
    url = ""
};

public OnPluginStart() {
    RegAdminCmd("sm_p_mute", Perma_Mute, ADMFLAG_SLAY);
    RegAdminCmd("sm_p_unmute", Perma_Mute, ADMFLAG_SLAY);
    RegAdminCmd("sm_p_gag", Perma_Mute, ADMFLAG_SLAY);
    RegAdminCmd("sm_p_ungag", Perma_Mute, ADMFLAG_SLAY);
    RegAdminCmd("sm_p_silence", Perma_Mute, ADMFLAG_SLAY);
    RegAdminCmd("sm_p_unsilence", Perma_Mute, ADMFLAG_SLAY);
}

public Action::Perma_Mute(client, args) {
    if (args < 2) {
        PrintToConsole(client, "[SM] Usage: sm_mute <player_name>");
        return Plugin_Handled;
    }
}