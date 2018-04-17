/*
* 
* TK Manager
* https://forums.alliedmods.net/showthread.php?t=79880
* 
* Description:
* This is a basic automated team kill/wound manager. It does not use
* any forgive menus or input from players, it just uses a point
* system to detect intentional team killers. Players can gain points
* for team kills and team wounds, and lose points for enemy kills.
* When the player reaches the limit, it either kicks or bans the
* player depending on configuration.
* 
* 
* Changelog
* Nov 26, 2013 - v.1.10:
* 				[*] Fixed race condition with database connection
*				[*] Fixed consecutive TK count not being reset when sm_tk_numkills = 0
*				[*] Optimized event binding
* Nov 25, 2013 - v.1.9.1:
* 				[*] Fixed hooking npc_killed on the wrong games
* Nov 18, 2013 - v.1.9:
* 				[+] Added detection of NPC kills in NMRiH
*`				[+] Added MySQL support
* Mar 22, 2011 - v.1.8:
* 				[+] Added translation support
* Jun 03, 2010 - v.1.7:
* 				[*] Fixed error on database connection
* Jun 02, 2010 - v.1.6:
* 				[*] Converted to threaded queries
* Sep 22, 2009 - v.1.5:
* 				[*] Fixed late database connection
* Aug 31, 2009 - v.1.4:
* 				[+] Added check to avoid duplicate bans
* 				[*] Changed some ConVar descriptions for clarity
* Aug 30, 2009 - v.1.3:
* 				[+] Added sm_tk_maxtk_punishtype and sm_tk_maxtk_bantime
* 				[+] Added sm_tk_db to set which database configuration to use
* 				[*] Changed immunity to be based on any admin access
* Nov 28, 2008 - v.1.2:
* 				[*] Added sm_tk_displaymode
* Nov 03, 2008 - v.1.1:
* 				[*] Changed database connection to use the standard named configuration method
* 				[*] Fixed version cvar being added to tk_manager.cfg
* Oct 31, 2008 - v.1.0:
* 				[*] Initial Release
* 
*/

#pragma semicolon 1
#include <sourcemod>
#include <morecolors>
#include <sdktools>

#define PLUGIN_VERSION "1.10-private"
#define SND_ATTACK "bot/stop_it.wav"
//#define DEBUG

public Plugin:myinfo = 
{
	name = "TK Manager",
	author = "Stevo.TVR, muso.sk",
	description = "Manages Team Kills based on a point system",
	version = PLUGIN_VERSION,
	url = "http://www.theville.org/"
}

new Handle:hDatabase = INVALID_HANDLE;

new Handle:sm_tk_maxpoints = INVALID_HANDLE;
new Handle:sm_tk_punishtype = INVALID_HANDLE;
new Handle:sm_tk_bantime = INVALID_HANDLE;
new Handle:sm_tk_numtw = INVALID_HANDLE;
new Handle:sm_tk_numkills = INVALID_HANDLE;
new Handle:sm_tk_maxtk = INVALID_HANDLE;
new Handle:sm_tk_maxtk_punishtype = INVALID_HANDLE;
new Handle:sm_tk_maxtk_bantime = INVALID_HANDLE;
new Handle:sm_tk_immunity = INVALID_HANDLE;
new Handle:sm_tk_persist = INVALID_HANDLE;
new Handle:sm_tk_displaymode = INVALID_HANDLE;
new Handle:sm_tk_db = INVALID_HANDLE;

new clientTKPoints[MAXPLAYERS+1];
new clientTW[MAXPLAYERS+1];
new clientTK[MAXPLAYERS+1];
new clientKills[MAXPLAYERS+1];
new bool:clientLocked[MAXPLAYERS+1];

public OnPluginStart()
{
	CreateConVar("sm_tkmanager_version", PLUGIN_VERSION, "TK Manager version", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	sm_tk_maxpoints = CreateConVar("sm_tk_maxpoints", "12", "Number of TK points before kick/ban", _, true, 0.0);
	sm_tk_punishtype = CreateConVar("sm_tk_punishtype", "0", "Action to take when sm_tk_maxpoints is reached (0 = ban, 1 = kick)", _, true, 0.0, true, 1.0);
	sm_tk_bantime = CreateConVar("sm_tk_bantime", "0", "Amount of time to ban if using sm_tk_punishtype 0 (0 = perm)", _, true, 0.0);
	sm_tk_numtw = CreateConVar("sm_tk_numtw", "3", "Number of team wounds to add 1 TK point (0 to disable team wound detection)", _, true, 0.0);
	sm_tk_numkills = CreateConVar("sm_tk_numkills", "2", "Number of real kills to subtract 1 TK point (0 to disable)", _, true, 0.0);
	sm_tk_maxtk = CreateConVar("sm_tk_maxtk", "4", "Number of consecutive team kills before kick/ban (0 to disable)", _, true, 0.0);
	sm_tk_maxtk_punishtype = CreateConVar("sm_tk_maxtk_punishtype", "1", "Action to take after maximum consecutive team kills (0 = ban, 1 = kick)", _, true, 0.0, true, 1.0);
	sm_tk_maxtk_bantime = CreateConVar("sm_tk_maxtk_bantime", "30", "Amount of time to ban if using sm_tk_maxtk_punishtype 0 (0 = perm)", _, true, 0.0);
	sm_tk_immunity = CreateConVar("sm_tk_immunity", "1", "Sets whether admins are immune to the TK manager", _, true, 0.0, true, 1.0);
	sm_tk_persist = CreateConVar("sm_tk_persist", "0", "Save TK points across map change", _, true, 0.0, true, 1.0);
	sm_tk_displaymode = CreateConVar("sm_tk_displaymode", "0", "Mode of displaying Team Kills (0 = None, 1 = Show Admins, 2 = Show All)", _, true, 0.0, true, 2.0);
	sm_tk_db = CreateConVar("sm_tk_db", "storage-local", "The named database config to use for storing TK points");

	AutoExecConfig(true, "tk_manager");
	
	HookConVarChange(sm_tk_numtw, OnConVarChanged);

	HookEvent("player_death", Event_PlayerDeath);
	
	decl String:game[16];
	GetGameFolderName(game, sizeof(game));
	if(strcmp(game, "nmrih", false) == 0)
	{
		HookEvent("npc_killed", Event_NPCKilled);
	}
	
	LoadTranslations("tkmanager.phrases");
}


public OnMapStart()
{
	PrecacheSound(SND_ATTACK, true);
}

public OnConfigsExecuted()
{
	if(hDatabase == INVALID_HANDLE)
	{
		decl String:db[64], String:error[256];
		GetConVarString(sm_tk_db, db, sizeof(db));
		hDatabase = SQL_Connect(db, true, error, sizeof(error));
		
		if(hDatabase == INVALID_HANDLE)
		{
			SetFailState(error);
		}
		SQL_TQuery(hDatabase, T_FastQuery, "CREATE TABLE IF NOT EXISTS tkmanager (steam_id VARCHAR(64) PRIMARY KEY, tkpoints INTEGER, numtk INTEGER, numtw INTEGER, numkills INTEGER);");
		
		if(GetConVarInt(sm_tk_numtw) > 0)
		{
			HookEvent("player_hurt", Event_PlayerHurt);
		}
	}
	
	if(!GetConVarBool(sm_tk_persist))
	{
		SQL_TQuery(hDatabase, T_FastQuery, "DELETE FROM tkmanager;");
	}
}

public OnConVarChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if(convar == sm_tk_numtw)
	{
		new oldVal = StringToInt(oldValue), newVal = StringToInt(newValue);
		if(oldVal <= 0 && newVal > 0)
		{
			HookEvent("player_hurt", Event_PlayerHurt);
		}
		else if(newVal <= 0 && oldVal > 0)
		{
			UnhookEvent("player_hurt", Event_PlayerHurt);
		}
	}
}

public OnClientAuthorized(client, const String:auth[])
{
	clientTKPoints[client] = 0;
	clientTW[client] = 0;
	clientTK[client] = 0;
	clientKills[client] = 0;
	
	if(IsFakeClient(client))
		return;
	
	decl String:query[1024];
	Format(query, sizeof(query), "SELECT * FROM tkmanager WHERE steam_id = '%s' LIMIT 1;", auth);
	SQL_TQuery(hDatabase, T_LoadPlayer, query, client);
}

public T_LoadPlayer(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if(hndl != INVALID_HANDLE)
	{
		if(SQL_FetchRow(hndl))
		{
			clientTKPoints[client] = SQL_FetchInt(hndl, 1);
			clientTK[client] = SQL_FetchInt(hndl, 2);
			clientTW[client] = SQL_FetchInt(hndl, 3);
			clientKills[client] = SQL_FetchInt(hndl, 4);
		}
	}
	
	clientLocked[client] = false;
	
#if defined DEBUG
	LogMessage("User %N has: %d TK points, %d TK, %d TW, %d kills", client, clientTKPoints[client], clientTK[client], clientTW[client], clientKills[client]);
#endif
}

public OnClientDisconnect(client)
{
	if(IsFakeClient(client))
		return;
	
	decl String:query[1024], String:authid[64];
	GetClientAuthId(client, AuthId_Steam2, authid, sizeof(authid));
	
	if(clientTKPoints[client] == 0 && clientTK[client] == 0)
	{
		Format(query, sizeof(query), "DELETE FROM tkmanager WHERE steam_id = '%s';", authid);
	}
	else
	{
		Format(query, sizeof(query), "REPLACE INTO tkmanager VALUES('%s', %d, %d, %d, %d);", authid, clientTKPoints[client], clientTK[client], clientTW[client], clientKills[client]);
	}
	SQL_TQuery(hDatabase, T_FastQuery, query, sizeof(query));
	
#if defined DEBUG
	LogMessage("Saving %N: %d TK points, %d TK, %d TW, %d kills", client, clientTKPoints[client], clientTK[client], clientTW[client], clientKills[client]);
#endif
}

public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	new user = GetClientOfUserId(GetEventInt(event, "attacker"));
	new victim = GetClientOfUserId(GetEventInt(event, "userid"));

	if(user == 0 || user == victim || IsFakeClient(user) || IsImmune(user))
		return Plugin_Continue;

	new team1 = GetClientTeam(user);
	new team2 = GetClientTeam(victim);
	
	if(team1 == team2)
	{
		clientTK[user]++;
		clientTKPoints[user]++;
		
#if defined DEBUG
		LogMessage("User %N has: %d (+1) TK points, %d TK (+1)", user, clientTKPoints[user], clientTK[user]);
#endif

		if(clientTKPoints[user] >= GetConVarInt(sm_tk_maxpoints))
		{
			HandleClient(user, true);
		}
		else if(GetConVarInt(sm_tk_maxtk) > 0 && clientTK[user] >= GetConVarInt(sm_tk_maxtk))
		{
			HandleClient(user, false);
		}
		else
		{
			CPrintToChat(user, "{chartreuse}[{dodgerblue}TeamKill{chartreuse}]{default} %t (%t: %d, %t: %d)", "Gained", "Total", clientTKPoints[user], "Limit", GetConVarInt(sm_tk_maxpoints));
		}
		
		new mode = GetConVarInt(sm_tk_displaymode);
		if(mode > 0)
		{
			for(new i = 1; i <= MaxClients; i++)
			{
				if(!IsClientInGame(i))
					continue;
					
				if(mode == 2 || GetUserAdmin(user) != INVALID_ADMIN_ID)
					CPrintToChat(i, "{chartreuse}[{dodgerblue}TeamKill{chartreuse}]{default} %N %t %N", user, "Team killed", victim);
			}
		}
	}
	else if(clientTKPoints[user] > 0)
	{
		clientKills[user]++;
		clientTK[user] = 0;
		
		if(clientKills[user] >= GetConVarInt(sm_tk_numkills) > 0)
		{
			clientTKPoints[user]--;
			clientKills[user] = 0;
		}
		
#if defined DEBUG
		LogMessage("User %N has: %d TK points, %d TK, %d (+1) kills", user, clientTKPoints[user], clientTK[user], clientKills[user]);
#endif
	}
	return Plugin_Continue;
}

public Action:Event_PlayerHurt(Handle:event, const String:name[], bool:dontBroadcast)
{
	new user = GetClientOfUserId(GetEventInt(event, "attacker"));
	new victim = GetClientOfUserId(GetEventInt(event, "userid"));



	
	if(user == 0 || user == victim || IsFakeClient(user) || IsImmune(user))
		return Plugin_Continue;
	
	new team1 = GetClientTeam(user);
	new team2 = GetClientTeam(victim);
	
	if(team1 == team2)
	{
		// How much damage do we need to reflect?
		new reflect_hp_dmg;
		new reflect_armor_dmg;
		reflect_hp_dmg    = GetEventInt(event, "dmg_health");
		reflect_armor_dmg = GetEventInt(event, "dmg_armor");

		// Reflect damage, possibly killing user
		new user_hp = GetClientHealth(user);
		new user_armor = GetClientArmor(user);

		if (reflect_hp_dmg >= user_hp)
			SetEntityHealth(user, 1);
		else {
			SetEntityHealth(user, user_hp - reflect_hp_dmg);
			if (reflect_armor_dmg >= user_armor)
				SetEntProp(user, Prop_Send, "m_ArmorValue", 0, 1);
			else SetEntProp(user, Prop_Send, "m_ArmorValue", user_armor - reflect_armor_dmg, 1);
		}

		new Handle:values = CreateKeyValues("msg", "", "");
		KvSetString(values, "title", "TeamAttack!!!");
		KvSetColor(values, "color", 255, 0, 0, 255);
		KvSetNum(values, "level", 1);
		KvSetNum(values, "time", 1);
		CreateDialog(user, values, DialogType:0);
		CloseHandle(values);
		EmitSoundToClient(user, SND_ATTACK); 
		clientTW[user]++;
			
#if defined DEBUG
	LogMessage("User %N has: %d TK points, %d TK, %d (+1) TW, %d kills", user, clientTKPoints[user], clientTK[user], clientTW[user], clientKills[user]);
#endif
	
		for(new i = 1; i <= MaxClients; i++)
		{
  			if(IsClientInGame(i) && CheckCommandAccess(i, "admin_msgs", ADMFLAG_BAN, true))
				CPrintToChat(i, "{chartreuse}[{dodgerblue}TeamKill{chartreuse}]{default} %N Team attacked %N", user, victim);
		}

		if(clientTW[user] >= GetConVarInt(sm_tk_numtw))
		{
			clientTKPoints[user]++	;
			clientTW[user] = 0;
		}
		if(clientTKPoints[user] >= GetConVarInt(sm_tk_maxpoints))
		{
			HandleClient(user, true);
		}
	}
	return Plugin_Continue;
}

public Action:Event_NPCKilled(Handle:event, const String:name[], bool:dontBroadcast)
{
	new user = GetEventInt(event, "killeridx");
	
	if(user == 0 || user > MaxClients || IsFakeClient(user) || IsImmune(user))
		return Plugin_Continue;
	
	if(clientTKPoints[user] > 0)
	{
		clientKills[user]++;
		clientTK[user] = 0;
		
		if(clientKills[user] >= GetConVarInt(sm_tk_numkills) > 0)
		{
			clientTKPoints[user]--;
			clientKills[user] = 0;
		}
#if defined DEBUG
		LogMessage("User %N has: %d TK points, %d TK, %d (+1) kills", user, clientTKPoints[user], clientTK[user], clientKills[user]);
#endif
	}
	return Plugin_Continue;
}

public HandleClient(client, bool:tkLimit)
{
	if(IsClientConnected(client) && !clientLocked[client])
	{
		clientLocked[client] = true;
		if(tkLimit)
		{
			if(GetConVarInt(sm_tk_punishtype) == 0)
			{
				ServerCommand("sm_ban #%d %d \"[TeamKill] %T\"", GetClientUserId(client), GetConVarInt(sm_tk_bantime), "Ban reason", LANG_SERVER);
				LogAction(0, client, "\"%L\" %T", client, "Banned", LANG_SERVER); 
			}
			else
			{
				KickClient(client, "%t", "Kicked");
			}
		}
		else
		{
			if(GetConVarInt(sm_tk_maxtk_punishtype) == 0)
			{
				ServerCommand("sm_ban #%d %d \"[TeamKill] %T\"", GetClientUserId(client), GetConVarInt(sm_tk_maxtk_bantime), "Ban reason", LANG_SERVER);
				LogAction(0, client, "\"%L\" %T", client, "Banned", LANG_SERVER); 
			}
			else
			{
				KickClient(client, "%t", "Kicked");
			}
		}
	}
}

public T_FastQuery(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	// Nothing to do
}

public IsImmune(client)
{
	new bool:immune = false;
	if(GetConVarBool(sm_tk_immunity))
	{
		if(GetUserFlagBits(client) == ADMFLAG_CUSTOM2)
			immune = true;
	}
	return immune;
}