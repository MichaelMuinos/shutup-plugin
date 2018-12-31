#include <sourcemod>
#include <basecomm>
#include <regex>

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo = {
    name = "Shutup Plugin",
    author = "Michael (JustPlainGoat) Muinos",
    description = "Ability to Perma-mute and Perma-gag a player.",
    version = PLUGIN_VERSION,
    url = "https://github.com/MichaelMuinos/Shutup-Plugin"
}

// Database object
Database g_ShutupDatabase;

// array to cache client mutes
bool g_ClientMuted[MAXPLAYERS + 1];

// array to cache client gags
bool g_ClientGagged[MAXPLAYERS + 1];

// keeps track of the available punishments
enum Punishment {
    MUTE,
    GAG
}

public void OnPluginStart() {
    // Create error buffer
    char error[256];

    // init our database connection
    g_ShutupDatabase = SQL_Connect("shutup_accounts", true, error, sizeof(error));

    if (!g_ShutupDatabase) {
        SetFailState("Could not connect to shutup accounts database: %s", error);
    }

    // Create a repeated timer to poll all mute and gagged players.
    // This is used to unmute/ungag players when the time runs out
    // and delete rows from the database that are no longer needed.
    CreateTimer(60.0, RepeatedTimerHandler, _, TIMER_REPEAT);

    RegAdminCmd("sm_p_mute", Perma_Mute, ADMFLAG_ROOT);
    RegAdminCmd("sm_p_unmute", Perma_Unmute, ADMFLAG_ROOT);
    RegAdminCmd("sm_p_gag", Perma_Gag, ADMFLAG_ROOT);
    RegAdminCmd("sm_p_ungag", Perma_Ungag, ADMFLAG_ROOT);
    RegAdminCmd("sm_p_silence", Perma_Silence, ADMFLAG_ROOT);
    RegAdminCmd("sm_p_unsilence", Perma_Unsilence, ADMFLAG_ROOT);
}

public void OnPluginEnd() {
    if (g_ShutupDatabase) {
        delete g_ShutupDatabase;
    }
}

// ----------------------------------------- START: Client Connected Functions -------------------------------------------------------- //

public void OnClientConnected(int client) {
    g_ClientMuted[client] = false;
    g_ClientGagged[client] = false;
}

public void OnClientAuthorized(int client) {
    int account = GetSteamAccountID(client);
    // query our database
    ContinueOngoingPlayerPunishment(account, client, MUTE);
    ContinueOngoingPlayerPunishment(account, client, GAG);
}

public void ContinueOngoingPlayerPunishment(int account, int client, Punishment punishment) {
    char queryStr[1024], tableName[256];
    Format(tableName,
           sizeof(tableName),
           punishment == MUTE ? "mutelist" : "gaglist");
    Format(queryStr,
           sizeof(queryStr),
           "SELECT account FROM %s WHERE account = %d AND (end_time > %d OR end_time = 0)",
           tableName,
           account,
           GetTime());

    // Lock the database
    SQL_LockDatabase(g_ShutupDatabase);
    // Query for the results
    DBResultSet query = SQL_Query(g_ShutupDatabase, queryStr);
    // Unlock the database
    SQL_UnlockDatabase(g_ShutupDatabase);

    if (query) {
        if (client && query.RowCount) {
            if (punishment == MUTE) {
                g_ClientMuted[client] = true;
            } else {
                g_ClientGagged[client] = true;
            }

            if (IsClientInGame(client)) {
                OnClientPutInServer(client);
            }
        }
        // delete our query
        delete query;
    }
}

public void OnClientPutInServer(int client) {
    if (g_ClientMuted[client]) {
        BaseComm_SetClientMute(client, true);
    }
    if (g_ClientGagged[client]) {
        BaseComm_SetClientGag(client, true);
    }
}

// ----------------------------------------- END: Client Connected Functions -------------------------------------------------------- //

// ----------------------------------------- START: Timer Command Functions -------------------------------------------------------- //

public Action RepeatedTimerHandler(Handle timer) {
    int time = GetTime();
    for (new i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            int account = GetSteamAccountID(i);
            // if we have a valid steam account id, we must query for it in the database.
            // If we have a valid match by account, we check if the punishment has been fulfilled.
            // If it has, we can ungag/unmute the player immediately.
            // This allows for "real-time" (give or take however long the timer interval is) tracking of the 
            if (account != 0) {
                RemoveExpiredPlayerPunishment(account, time, i, MUTE);
                RemoveExpiredPlayerPunishment(account, time, i, GAG);
            }
        }
    }
    
    // delete any mute/gag punishments that are expired.
    // i.e. the current time is greater than the end time
    DeleteExpiredPunishments(time, MUTE);
    DeleteExpiredPunishments(time, GAG);

    return Plugin_Continue;
}

public void RemoveExpiredPlayerPunishment(int account, int time, int client, Punishment punishment) {
    // Create the query
    char queryStr[1024], tableName[256];
    Format(tableName,
           sizeof(tableName),
           punishment == MUTE ? "mutelist" : "gaglist");
    Format(queryStr,
           sizeof(queryStr),
           "SELECT account FROM %s WHERE account = %d AND end_time != 0 AND end_time < %d",
           tableName,
           account,
           time);
    
    // Lock the database
    SQL_LockDatabase(g_ShutupDatabase);
    // Query for the results
    DBResultSet query = SQL_Query(g_ShutupDatabase, queryStr);
    // Unlock the database
    SQL_UnlockDatabase(g_ShutupDatabase);

    // Check if the user fulfilled the punishment.
    // If he/she has, we can unmute/ungag immediately if they are still in the game. 
    if (query) {
        if (IsClientInGame(client) && query.RowCount) {
            if (punishment == MUTE) {
                BaseComm_SetClientMute(client, false);
            } else {
                BaseComm_SetClientGag(client, false);
            }
        }
        // delete the query
        delete query;
    }
}

public void DeleteExpiredPunishments(int time, Punishment punishment) {
    char error[256], tableName[256];
    Format(tableName,
           sizeof(tableName),
           punishment == MUTE ? "mutelist" : "gaglist");
    // now, we must query through our database and remove any punishments that are already fulfilled.
    // This is needed to ensure the tables are not filled with "dead" punishments.
    // i.e. where the current time is greater than the end_time.
    DBStatement g_DeleteQuery = SQL_PrepareQuery(g_ShutupDatabase,
                                                 "DELETE FROM ? WHERE end_time != 0 AND end_time < ?;",
                                                 error,
                                                 sizeof(error));  
                                                                                              
    // check to ensure the query was created properly
    if (!g_DeleteQuery) {
        LogAction(0, -1, "Could not create prepared statement g_DeleteQuery in DeleteExpiredPunishments: %s", error);
        return;
    }

    // bind our query with the table name and time
    g_DeleteQuery.BindString(0, tableName, false);
    g_DeleteQuery.BindInt(1, time);

    // Lock the database
    SQL_LockDatabase(g_ShutupDatabase);
    // execute the query
    SQL_Execute(g_DeleteQuery);
    // Unlock the database
    SQL_UnlockDatabase(g_ShutupDatabase);

    // finally, delete our query
    if (g_DeleteQuery) {
        delete g_DeleteQuery;
    }
}

// ----------------------------------------- END: Timer Command Functions -------------------------------------------------------- //

public Action Perma_Mute(int client, int args) {
    IssuePunishmentCommand(client, args, MUTE);
    return Plugin_Handled;
}

public Action Perma_Unmute(int client, int args) {
    RemovePunishmentCommand(client, args, MUTE);
    return Plugin_Handled;
}

public Action Perma_Gag(int client, int args) {
    IssuePunishmentCommand(client, args, GAG);
    return Plugin_Handled;
}

public Action Perma_Ungag(int client, int args) {
    RemovePunishmentCommand(client, args, GAG);
    return Plugin_Handled;
}

public Action Perma_Silence(int client, int args) {
    IssuePunishmentCommand(client, args, MUTE);
    IssuePunishmentCommand(client, args, GAG);
    return Plugin_Handled;
}

public Action Perma_Unsilence(int client, int args) {
    RemovePunishmentCommand(client, args, MUTE);
    RemovePunishmentCommand(client, args, GAG);
    return Plugin_Handled;
}

public void IssuePunishmentCommand(int client, int args, Punishment punishment) {
    if (args < 2) {
        char command[64];
        GetCmdArg(0, command, sizeof(command));
        ReplyToCommand(client, "Usage: %s <time> <name>", command);
        return;
    }

    char time[50], arg_string[256];
	GetCmdArgString(arg_string, sizeof(arg_string));
	
	int len, total_len;
	if ((len = BreakString(arg_string, time, sizeof(time))) == -1) {
		char command[64];
		GetCmdArg(0, command, sizeof(command));
		ReplyToCommand(client, "Usage: %s <time> <name>", command);
		return;
	}
	total_len += len;

    // find the target client
    int target = FindTarget(client, arg_string[total_len]);
    if (target == -1) {
        ReplyToCommand(client, "Could not find client with name \"%s\"", arg_string[total_len]);
        return;
    }

    // extract the steam account id from the target
    int account = GetSteamAccountID(target);
    if (account == 0) {
        ReplyToCommand(client, "Could not fetch steam account ID from client \"%s\"", arg_string[total_len]);
        return;
    }
	
    // save the account to the table to carry out the punishment
    int minutes = StringToInt(time);
    AddOrReplacePunishment(account, minutes, client, punishment);
    ReplyToCommand(client, "Added %s (minutes \"%d\") (id \"%d\")", punishment == MUTE ? "mute" : "gag", minutes, account);

    // immediately perform punishment to player if they are in the server
    if (IsClientInGame(target)) {
        if (punishment == MUTE) {
            BaseComm_SetClientMute(target, true);
            g_ClientMuted[target] = true;
            ReplyToCommand(client, "Muted \"%L\" to start the mute ", target);
        } else {
            BaseComm_SetClientGag(target, true);
            g_ClientGagged[target] = true;
            ReplyToCommand(client, "Gagged \"%L\" to start the gag ", target);
        }
    }
}

public void RemovePunishmentCommand(int client, int args, Punishment punishment) {
    if (args < 1) {
        char command[64];
        GetCmdArg(0, command, sizeof(command));
        ReplyToCommand(client, "Usage: %s <name>", command);
        return;
    }

    char arg_string[256];
    GetCmdArgString(arg_string, sizeof(arg_string));

    LogAction(0, -1, "%s for name %s", punishment == MUTE ? "mute" : "gag", arg_string[0]);

    // find target client
    int target = FindTarget(client, arg_string[0]);
    if (target == -1) {
        ReplyToCommand(client, "Could not find client with name \"%s\"", arg_string[0]);
        return;
    }

    // extract the steam account id from the target
    int account = GetSteamAccountID(target);
    if (account == 0) {
        ReplyToCommand(client, "Could not fetch steam account ID from client \"%s\"", arg_string[0]);
        return;
    }

    // remove punishment from client and remove punishment from database if present
    RemovePunishmentByAdmin(account, client, target, punishment);
}

public void AddOrReplacePunishment(int account, int minutes, int source, Punishment punishment) {
    char error[256], tableName[256];
    Format(tableName,
           sizeof(tableName),
           punishment == MUTE ? "mutelist" : "gaglist");
    // Create our query for adding a punishment
    DBStatement g_AddQuery = SQL_PrepareQuery(g_ShutupDatabase,     // reference to DB object
                                              "INSERT INTO ? (account, start_time, end_time, admin_account) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE start_time = ?, end_time = ?, admin_account = ?;",  // query statement
                                              error,      // error buffer
                                              sizeof(error));     // size of error buffer

    if (!g_AddQuery) {
        LogAction(0, -1, "Could not create prepared statement g_AddQuery in AddPunishment: %s", error);
        return;
    }

    // convert minutes to seconds
    int endTime = minutes ? (GetTime() + (minutes * 60)) : 0;
    int sourceAccount = source ? GetSteamAccountID(source) : 0;
    
    // create insert query with data
    g_AddQuery.BindString(0, tableName, false);
    g_AddQuery.BindInt(1, account);
    g_AddQuery.BindInt(2, GetTime());
    g_AddQuery.BindInt(3, endTime);
    g_AddQuery.BindInt(4, sourceAccount);
    g_AddQuery.BindInt(5, GetTime());
    g_AddQuery.BindInt(6, endTime);
    g_AddQuery.BindInt(7, sourceAccount);
    
    // lock the database
    SQL_LockDatabase(g_ShutupDatabase);
    // execute the query
    SQL_Execute(g_AddQuery);
    // unlock the database
    SQL_UnlockDatabase(g_ShutupDatabase);

    delete g_AddQuery;
}

public void RemovePunishmentByAdmin(int account, int client, int target, Punishment punishment) {
    // Create the query
    char queryStr[1024], tableName[256];
    Format(tableName,
           sizeof(tableName),
           punishment == MUTE ? "mutelist" : "gaglist");
    Format(queryStr,
           sizeof(queryStr),
           "SELECT account FROM %s WHERE account = %d",
           tableName,
           account);
    
    // Lock the database
    SQL_LockDatabase(g_ShutupDatabase);
    // Query for the results
    DBResultSet query = SQL_Query(g_ShutupDatabase, queryStr);
    // Unlock the database
    SQL_UnlockDatabase(g_ShutupDatabase);

    if (query) {
        // if we have a result, that means we can delete the punishment from the database
        if (query.RowCount) {
            // if our client is in the game, we can ungag immediately
            if (IsClientInGame(target)) {
                if (punishment == MUTE) {
                    BaseComm_SetClientMute(target, false);
                    ReplyToCommand(client, "Unmuted \"%L\". Punishment has been removed.", target);
                } else {
                    BaseComm_SetClientGag(target, false);
                    ReplyToCommand(client, "Ungagged \"%L\". Punishment has been removed.", target);
                }
            }
            DeleteClientPunishment(account, punishment);
        }

        // delete our query
        delete query;
    }
}

public void DeleteClientPunishment(int account, Punishment punishment) {
    char error[256], tableName[256];
    Format(tableName,
           sizeof(tableName),
           punishment == MUTE ? "mutelist" : "gaglist");
    DBStatement g_DeleteQuery = SQL_PrepareQuery(g_ShutupDatabase,
                                                 "DELETE FROM ? WHERE account = ?;",
                                                 error,
                                                 sizeof(error));  
                                                                                              
    // check to ensure the query was created properly
    if (!g_DeleteQuery) {
        LogAction(0, -1, "Could not create prepared statement g_DeleteQuery in DeleteClientPunishment: %s", error);
        return;
    }

    // bind our query with the table name and account
    g_DeleteQuery.BindString(0, tableName, false);
    g_DeleteQuery.BindInt(1, account);

    // Lock the database
    SQL_LockDatabase(g_ShutupDatabase);
    // execute the query
    SQL_Execute(g_DeleteQuery);
    // Unlock the database
    SQL_UnlockDatabase(g_ShutupDatabase);

    // delete the query
    delete g_DeleteQuery;
}