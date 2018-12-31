#include <sourcemod>
#include <basecomm>
#include <regex>

#define PLUGIN_VERSION "0.0.1"

public Plugin myinfo = {
    name = "Shutup Plugin",
    author = "Michael Muinos",
    description = "Ability to Perma-mute and Perma-gag a player.",
    version = PLUGIN_VERSION,
    url = "https://github.com/MichaelMuinos/Shutup-Plugin"
}

// Database object
Database g_ShutupDatabase;

// DBStatement object used for adding a muted account
DBStatement g_AddMuteQuery;

// DBStatement object used for adding a gagged account
DBStatement g_AddGagQuery;

// array to cache client mutes
bool g_ClientMuted[MAXPLAYERS + 1];

// array to cache client gags
bool g_ClientGagged[MAXPLAYERS + 1];

public void OnPluginStart() {
    // Create error buffer
    char error[256];

    // init our database connection
    g_ShutupDatabase = SQL_Connect("shutup_accounts", true, error, sizeof(error));

    if (!g_ShutupDatabase) {
        SetFailState("Could not connect to shutup accounts database: %s", error);
    }

    // Create our query for adding mute accounts
    g_AddMuteQuery = SQL_PrepareQuery(g_ShutupDatabase,     // reference to DB object
                                    "INSERT INTO mutelist (account, start_time, end_time, admin_account) VALUES (?, ?, ?, ?);",  // query statement
                                    error,      // error buffer
                                    sizeof(error));     // size of error buffer

    if (!g_AddMuteQuery) {
        SetFailState("Could not create prepared statement g_AddMuteQuery: %s", error);
    }

    // Create our query for adding gag accounts
    g_AddGagQuery = SQL_PrepareQuery(g_ShutupDatabase,     // reference to DB object
                                    "INSERT INTO gaglist (account, start_time, end_time, admin_account) VALUES (?, ?, ?, ?);",   // query statement
                                    error,      // error buffer
                                    sizeof(error));     // size of error buffer

    if (!g_AddGagQuery) {
        SetFailState("Could not create prepared statement g_AddGagQuery: %s", error);
    }

    // Create a repeated timer to poll all mute and gagged players.
    // This is used to unmute/ungag players when the time runs out
    // and delete rows from the database that are no longer needed.
    CreateTimer(60.0, RepeatedTimerHandler, _, TIMER_REPEAT);

    // RegAdminCmd("sm_p_mute", Perma_Mute, ADMFLAG_ROOT);
    // RegAdminCmd("sm_p_unmute", Perma_Unmute, ADMFLAG_SLAY);
    RegAdminCmd("sm_p_gag", Perma_Gag, ADMFLAG_ROOT);
    RegAdminCmd("sm_p_ungag", Perma_Ungag, ADMFLAG_ROOT);
    // RegAdminCmd("sm_p_silence", Perma_Silence, ADMFLAG_SLAY);
    // RegAdminCmd("sm_p_unsilence", Perma_Unsilence, ADMFLAG_SLAY);
}

public void OnPluginEnd() {
    delete g_AddMuteQuery;
    delete g_AddGagQuery;
}

public void OnClientConnected(int client) {
    g_ClientMuted[client] = false;
    g_ClientGagged[client] = false;
}

public void OnClientAuthorized(int client) {
    int account = GetSteamAccountID(client);
    // query our database
    GagClientIfUnfulfilledPunishment(account, client);
    MuteClientIfUnfulfilledPunishment(account, client);
}

public void OnClientPutInServer(int client) {
    if (g_ClientMuted[client]) {
        BaseComm_SetClientMute(client, true);
        LogAction(0, client, "Muted \"%L\" for an ongoing mute punishment.", client);
    }
    if (g_ClientGagged[client]) {
        BaseComm_SetClientGag(client, true);
        LogAction(0, client, "Gagged \"%L\" for an ongoing gag punishment.", client);
    }
}

public Action RepeatedTimerHandler(Handle timer) {
    int time = GetTime();
    for (new i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            int account = GetSteamAccountID(i);
            // if we have a valid steam account id, we must query for it in the database.
            // If we have a valid match by account, we check if the punishment has been fulfilled.
            // If it has, we can ungag/unmute the player immediately.
            // This allows for "real-time" (give or take however long the timer interval is) tracking of the punishment.
            if (account != 0) {
                UngagClientIfFulfilledPunishment(account, time, i);
            }
        }
    }
    
    // delete any gag punishments that are expired.
    // i.e. the current time is greater than the end time
    DeleteExpiredGagPunishments(time);

    return Plugin_Continue;
}

public void GagClientIfUnfulfilledPunishment(int account, int client) {
    char gagQuery[1024];
    // query database for gag
    Format(gagQuery,
           sizeof(gagQuery),
           "SELECT account FROM gaglist WHERE account = %d AND (end_time > %d OR end_time = 0)",
           account,
           GetTime());

    // Lock the database
    SQL_LockDatabase(g_ShutupDatabase);
    // Query for the results
    DBResultSet query = SQL_Query(g_ShutupDatabase, gagQuery);
    // Unlock the database
    SQL_UnlockDatabase(g_ShutupDatabase);
    
    if (client && query && query.RowCount) {
        g_ClientGagged[client] = true;
        if (IsClientInGame(client)) {
            OnClientPutInServer(client);
        }
    }
}

public void MuteClientIfUnfulfilledPunishment(int account, int client) {
    char muteQuery[1024];
    // query database for mute
    Format(muteQuery,       // buffer for query
           sizeof(muteQuery),       // size of buffer
           "SELECT account FROM mutelist WHERE account = %d AND (end_time > %d OR end_time = 0)",   // query statement
           account,     // account id to query by
           GetTime());      // current time to be used for comparing to end_time column
    
    // Lock the database
    SQL_LockDatabase(g_ShutupDatabase);
    // Query for the results
    DBResultSet query = SQL_Query(g_ShutupDatabase, muteQuery);
    // Unlock the database
    SQL_UnlockDatabase(g_ShutupDatabase);

    if (client && query && query.RowCount) {
        g_ClientMuted[client] = true;
        if (IsClientInGame(client)) {
            OnClientPutInServer(client);
        }
    }
}

public void UngagClientIfFulfilledPunishment(int account, int time, int client) {
    // Create the query
    char gagQuery[1024];
    Format(gagQuery,
            sizeof(gagQuery),
            "SELECT account FROM gaglist WHERE account = %d AND end_time != 0 AND end_time < %d",
            account,
            time);
    
    // Lock the database
    SQL_LockDatabase(g_ShutupDatabase);
    // Query for the results
    DBResultSet query = SQL_Query(g_ShutupDatabase, gagQuery);
    // Unlock the database
    SQL_UnlockDatabase(g_ShutupDatabase);

    // Check if the user fulfilled the punishment.
    // If he/she has, we can ungag immediately if there are still in the game. 
    if (IsClientInGame(client) && query && query.RowCount) {
        BaseComm_SetClientGag(client, false);
        LogAction(0, client, "Ungagged \"%L\". Punishment has been fulfilled.", client);
    }

    // finally, delete our query
    delete query;
}

public void UngagClientIfHasPunishment(int account, int client) {
    // Create the query
    char gagQuery[1024];
    Format(gagQuery,
            sizeof(gagQuery),
            "SELECT account FROM gaglist WHERE account = %d",
            account);
    
    // Lock the database
    SQL_LockDatabase(g_ShutupDatabase);
    // Query for the results
    DBResultSet query = SQL_Query(g_ShutupDatabase, gagQuery);
    // Unlock the database
    SQL_UnlockDatabase(g_ShutupDatabase);

    if (query) {
        // if we have a result, that means we can delete the punishment from the database
        if (query.RowCount) {
            // if our client is in the game, we can ungag immediately
            if (IsClientInGame(client)) {
                BaseComm_SetClientGag(client, false);
                LogAction(0, client, "Ungagged \"%L\". Punishment has been removed by an admin.", client);
            }
            DeleteClientGagPunishment(account);
        }
    }

    delete query;
}

public void DeleteClientGagPunishment(int account) {
    char error[256];
    DBStatement g_DeleteGagQuery = SQL_PrepareQuery(g_ShutupDatabase,
                                                    "DELETE FROM gaglist WHERE account = ?;",
                                                    error,
                                                    sizeof(error));  
                                                                                              
    // check to ensure the query was created properly
    if (!g_DeleteGagQuery) {
        LogAction(0, -1, "Could not create prepared statement g_DeleteGagQuery: %s", error);
        return;
    }

    // bind our query with the time
    g_DeleteGagQuery.BindInt(0, account);

    // Lock the database
    SQL_LockDatabase(g_ShutupDatabase);
    // execute the query
    SQL_Execute(g_DeleteGagQuery);
    // Unlock the database
    SQL_UnlockDatabase(g_ShutupDatabase);

    // delete the query
    delete g_DeleteGagQuery;
}

public void DeleteExpiredGagPunishments(int time) {
    char error[256];
    // now, we must query through our database and remove any punishments that are already fulfilled.
    // This is needed to ensure the tables are not filled with "dead" punishments.
    // i.e. where the current time is greater than the end_time.
    DBStatement g_DeleteGagQuery = SQL_PrepareQuery(g_ShutupDatabase,
                                                    "DELETE FROM gaglist WHERE end_time != 0 AND end_time < ?;",
                                                    error,
                                                    sizeof(error));  
                                                                                              
    // check to ensure the query was created properly
    if (!g_DeleteGagQuery) {
        LogAction(0, -1, "Could not create prepared statement g_DeleteGagQuery: %s", error);
        return;
    }

    // bind our query with the time
    g_DeleteGagQuery.BindInt(0, time);

    // Lock the database
    SQL_LockDatabase(g_ShutupDatabase);
    // execute the query
    SQL_Execute(g_DeleteGagQuery);
    // Unlock the database
    SQL_UnlockDatabase(g_ShutupDatabase);

    // delete the query
    delete g_DeleteGagQuery;
}

public void AddGagPunishment(int account, int minutes, int source) {
    // convert minutes to seconds
    int endTime = minutes ? (GetTime() + (minutes * 60)) : 0;
    int sourceAccount = source ? GetSteamAccountID(source) : 0;
    
    // create insert query with data
    g_AddGagQuery.BindInt(0, account);
    g_AddGagQuery.BindInt(1, GetTime());
    g_AddGagQuery.BindInt(2, endTime);
    g_AddGagQuery.BindInt(3, sourceAccount);
    
    // lock the database
    SQL_LockDatabase(g_ShutupDatabase);
    // execute the query
    SQL_Execute(g_AddGagQuery);
    // unlock the database
    SQL_UnlockDatabase(g_ShutupDatabase);
}

// ----------------------------------------- START: Actions for admin commands -------------------------------------------------------- //

public Action Perma_Gag(int client, int args) {
    if (args < 2) {
        char command[64];
        GetCmdArg(0, command, sizeof(command));
        ReplyToCommand(client, "Usage: %s <time> <name>", command);
        return Plugin_Handled;
    }

    char time[50], arg_string[256];
	GetCmdArgString(arg_string, sizeof(arg_string));
	
	int len, total_len;
	if ((len = BreakString(arg_string, time, sizeof(time))) == -1) {
		char command[64];
		GetCmdArg(0, command, sizeof(command));
		ReplyToCommand(client, "Usage: %s <time> <name>", command);
		return Plugin_Handled;
	}
	total_len += len;

    // find the target client
    int target = FindTarget(client, arg_string[total_len]);
    if (target == -1) {
        ReplyToCommand(client, "Could not find client with name \"%s\"", arg_string[total_len]);
        return Plugin_Handled;
    }

    // extract the steam account id from the target
    int account = GetSteamAccountID(target);
    if (account == 0) {
        ReplyToCommand(client, "Could not fetch steam account ID from client \"%s\"", arg_string[total_len]);
        return Plugin_Handled;
    }
	
    // save the account to the gaglist table to carry out the punishment
    int minutes = StringToInt(time);
    AddGagPunishment(account, minutes, client);
    LogAction(client, -1, "\"%L\" added mute (minutes \"%d\") (id \"%d\")", client, minutes, account);

    // immediately gag player if they are in the server
    if (IsClientInGame(target)) {
        BaseComm_SetClientGag(target, true);
        g_ClientGagged[target] = true;
        LogAction(0, target, "Gagged \"%L\" to start the gag punishment.", target);
    }

    // end
    return Plugin_Handled;
}

public Action Perma_Ungag(int client, int args) {
    if (args < 1) {
        char command[64];
        GetCmdArg(0, command, sizeof(command));
        ReplyToCommand(client, "Usage: %s <name>", command);
        return Plugin_Handled;
    }

    char arg_string[256];
    GetCmdArgString(arg_string, sizeof(arg_string));

    LogAction(0, -1, "Ungag for name %s", arg_string[0]);

    // find target client
    int target = FindTarget(client, arg_string[0]);
    if (target == -1) {
        ReplyToCommand(client, "Could not find client with name \"%s\"", arg_string[0]);
        return Plugin_Handled;
    }

    // extract the steam account id from the target
    int account = GetSteamAccountID(target);
    if (account == 0) {
        ReplyToCommand(client, "Could not fetch steam account ID from client \"%s\"", arg_string[0]);
        return Plugin_Handled;
    }

    // ungag client and remove punishment from database if present
    UngagClientIfHasPunishment(account, target);   

    // end
    return Plugin_Handled; 
}

// ----------------------------------------- END: Actions for admin commands -------------------------------------------------------- //