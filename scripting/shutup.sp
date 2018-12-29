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
                                    "INSERT INTO mutelist (account, start_time, end_time, reason, admin_account) VALUES (?, ?, ?, ?, ?);",  // query statement
                                    error,      // error buffer
                                    sizeof(error));     // size of error buffer

    if (!g_AddMuteQuery) {
        SetFailState("Could not create prepared statement g_AddMuteQuery: %s", error);
    }

    // Create our query for adding gag accounts
    g_AddGagQuery = SQL_PrepareQuery(g_ShutupDatabase,     // reference to DB object
                                    "INSERT INTO gaglist (account, start_time, end_time, reason, admin_account) VALUES (?, ?, ?, ?, ?);",   // query statement
                                    error,      // error buffer
                                    sizeof(error));     // size of error buffer

    if (!g_AddGagQuery) {
        SetFailState("Could not create prepared statement g_AddGagQuery: %s", error);
    }

    RegAdminCmd("sm_p_mute", Perma_Mute, ADMFLAG_ROOT);
    // RegAdminCmd("sm_p_unmute", Perma_Unmute, ADMFLAG_SLAY);
    RegAdminCmd("sm_p_gag", Perma_Gag, ADMFLAG_ROOT);
    // RegAdminCmd("sm_p_ungag", Perma_Unmute, ADMFLAG_SLAY);
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
    // query database for both mute and gag by account
    QueryDatabaseHelper(client, account, true, OnQueriedClientMute);
    QueryDatabaseHelper(client, account, false, OnQueriedClientGag);
}

public void QueryDatabaseHelper(int client, int account, bool isMute, SQLQueryCallback callback) {
    char query[1024], tableName[256];

    Format(tableName,
           sizeof(tableName),
           isMute ? "mutelist" : "gaglist");
    Format(query,       // buffer for query
           sizeof(query),       // size of buffer
           "SELECT account FROM %s WHERE account = %d AND (end_time > %d OR end_time = 0) LIMIT 1",   // query statement
           tableName,   // table name (either mutelist or gaglist)
           account,     // account id to query by
           GetTime());      // current time to be used for comparing to end_time column
    
    // query our database
    g_ShutupDatabase.Query(callback, query, GetClientUserId(client));
}

public void OnQueriedClientMute(Database database, DBResultSet results, const char[] error, int userId) {
    int client = GetClientOfUserId(userId);
    OnQueryClientHelper(client, results, g_ClientMuted);
}

public void OnQueriedClientGag(Database database, DBResultSet results, const char[] error, int userId) {
    int client = GetClientOfUserId(userId);
    OnQueryClientHelper(client, results, g_ClientGagged);
}

public void OnQueryClientHelper(int client, DBResultSet results, bool[] clientCache) {
    if (client && results && results.RowCount) {
        clientCache[client] = true;
        if (IsClientInGame(client)) {
            OnClientPutInServer(client);
        }
    }
}

public void OnClientPutInServer(int client) {
    if (g_ClientMuted[client]) {
        BaseComm_SetClientMute(client, true);
        LogAction(0, client, "Muted \"%L\" for an ongoing mute punishment.", client);
    }
    if (g_ClientGagged[client]) {
        BaseComm_SetClientGag(client, true);
        LogAction(0, client, "Muted \"%L\" for an ongoing gag punishment.", client);
    }
}

public Action Perma_Mute(int client, int args) {
    if (args < 2) {
        char command[64];
        GetCmdArg(0, command, sizeof(command));
        ReplyToCommand(client, "Usage: %s <time> <steamid> [reason]", command);
        return Plugin_Handled;
    }

    char time[50], authid[50], arg_string[256];
	
	GetCmdArgString(arg_string, sizeof(arg_string));
	
	int len, total_len;

	if ((len = BreakString(arg_string, time, sizeof(time))) == -1) {
		char command[64];
		GetCmdArg(0, command, sizeof(command));
		ReplyToCommand(client, "Usage: %s <time> <steamid> [reason]", command);
		return Plugin_Handled;
	}
	total_len += len;
	
	if ((len = BreakString(arg_string[total_len], authid, sizeof(authid))) != -1) {
		total_len += len;
	} else {
		total_len = 0;
		arg_string[0] = '\0';
	}
	
	int account;
	if (!strncmp(authid, "STEAM_", 6) && authid[7] == ':') {
		account = GetAccountIDFromAuthID(authid, AuthId_Steam2);
	} else if (!strncmp(authid, "[U:", 3)) {
		account = GetAccountIDFromAuthID(authid, AuthId_Steam3);
	}
	
	if (account) {
		int nMinutes = StringToInt(time);
		MuteByAccountID(account, nMinutes, arg_string[total_len], client);
		LogAction(client, -1, "\"%L\" added mute (minutes \"%d\") (id \"%s\") (reason \"%s\")", client, nMinutes, authid, arg_string[total_len]);
	}
    return Plugin_Handled;
}

void MuteByAccountID(int account, int nMinutes, const char[] reason = "No reason specified", int source = 0) {
	if (account) {
        // convert minutes to seconds
		int endTime = nMinutes ? (GetTime() + (nMinutes * 60)) : 0;
		int sourceAccount = source ? GetSteamAccountID(source) : 0;
		
        // create insert query with data
		g_AddMuteQuery.BindInt(0, account);
        g_AddMuteQuery.BindInt(1, GetTime());
		g_AddMuteQuery.BindInt(2, endTime);
		g_AddMuteQuery.BindString(3, reason, false);
		g_AddMuteQuery.BindInt(4, sourceAccount);
		
        // execute the query
		SQL_Execute(g_AddMuteQuery);
	}
}

void GagByAccountID(int account, int nMinutes, const char[] reason = "No reason specified", int source = 0) {
	if (account) {
        // convert minutes to seconds
		int endTime = nMinutes ? (GetTime() + (nMinutes * 60)) : 0;
		int sourceAccount = source ? GetSteamAccountID(source) : 0;
		
        // create insert query with data
		g_AddGagQuery.BindInt(0, account);
        g_AddGagQuery.BindInt(1, GetTime());
		g_AddGagQuery.BindInt(2, endTime);
		g_AddGagQuery.BindString(3, reason, false);
		g_AddGagQuery.BindInt(4, sourceAccount);
		
        // execute the query
		SQL_Execute(g_AddGagQuery);
	}
}

stock int GetAccountIDFromAuthID(const char[] auth, AuthIdType authid) {
	static Regex s_Steam2Format, s_Steam3Format;
	
	if (!s_Steam2Format) {
		s_Steam2Format = new Regex("STEAM_\\d:\\d:\\d+");
		s_Steam3Format = new Regex("\\[U:\\d:\\d+\\]");
	}
	
	switch (authid) {
		case AuthId_Steam3: {
			if (!s_Steam3Format.Match(auth)) {
			    ThrowError("Input string %s is not a SteamID3-formatted string.", auth);
			}
            
			int account;
			StringToIntEx(auth[FindCharInString(auth, ':', true) + 1], account);
			return account;
		}
		case AuthId_Steam2: {
			if (!s_Steam2Format.Match(auth)) {
				ThrowError("Input string %s is not a SteamID2-formatted string.", auth);
			}
			
			int y;
			StringToIntEx(auth[FindCharInString(auth, ':', false) + 1], y);
			int z = StringToInt(auth[FindCharInString(auth, ':', true) + 1]);
			return (2 * z) + y;
		}
	}
	return 0;
}

public Action Perma_Unmute(int client, int args) {

}

public Action Perma_Gag(int client, int args) {
    if (args < 2) {
        char command[64];
        GetCmdArg(0, command, sizeof(command));
        ReplyToCommand(client, "Usage: %s <time> <steamid> [reason]", command);
        return Plugin_Handled;
    }

    char time[50], authid[50], arg_string[256];
	
	GetCmdArgString(arg_string, sizeof(arg_string));
	
	int len, total_len;

	if ((len = BreakString(arg_string, time, sizeof(time))) == -1) {
		char command[64];
		GetCmdArg(0, command, sizeof(command));
		ReplyToCommand(client, "Usage: %s <time> <steamid> [reason]", command);
		return Plugin_Handled;
	}
	total_len += len;
	
	if ((len = BreakString(arg_string[total_len], authid, sizeof(authid))) != -1) {
		total_len += len;
	} else {
		total_len = 0;
		arg_string[0] = '\0';
	}
	
	int account;
	if (!strncmp(authid, "STEAM_", 6) && authid[7] == ':') {
		account = GetAccountIDFromAuthID(authid, AuthId_Steam2);
	} else if (!strncmp(authid, "[U:", 3)) {
		account = GetAccountIDFromAuthID(authid, AuthId_Steam3);
	}
	
	if (account) {
		int nMinutes = StringToInt(time);
		GagByAccountID(account, nMinutes, arg_string[total_len], client);
		LogAction(client, -1, "\"%L\" added mute (minutes \"%d\") (id \"%s\") (reason \"%s\")", client, nMinutes, authid, arg_string[total_len]);
	}
    return Plugin_Handled;
}

public Action Perma_Ungag(int client, int args) {
    
}

public Action Perma_Silence(int client, int args) {
    
}

public Action Perma_Unsilence(int client, int args) {
    
}