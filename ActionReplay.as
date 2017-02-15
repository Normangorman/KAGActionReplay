// Some important concepts
// 'recorded time' means a time returned by getGameTime() in the original recorded match
// 'fake time' refers to a recorded time. So if a match was recorded from ticks 10-100 then valid fake times are 10-100.
// 'sim time' means a time returned by getGameTime() but in the simulation
#define SERVER_ONLY

#include "Logging.as";
#include "RulesCore.as";


const int AR_RECORDING_VERSION = 1; // the version number for recording files. If the format changes this should be changed.
const float AR_RUBBERBAND_SNAP = 4.0; // If a blob's position strays more than this amount from it's recorded value then it will be moved.
const keys[] AR_ALL_KEYS = {
    key_up,
    key_down,
    key_left,
    key_right,
    key_action1,
    key_action2,
    key_action3,
    key_use,
    key_inventory,
    key_pickup,
    key_jump,
    key_taunts,
    key_map,
    key_bubbles,
    key_crouch
};


enum ARMode {
    recording = 0,
    replaying,
    idle
}


/* The current state of the mod
 */
class ModState {
    bool            autorecord = false;     // if true then matches are automatically recorded on state and saved on game over
    ARMode          mode = ARMode::idle;    // the current mode
    bool            hasRecording = false;   // whether we have a currentRecording
    MatchRecording  currentRecording;
    MatchReplay     currentReplay;

    bool isRecording() {
        return mode == ARMode::recording;
    }

    bool isReplaying() {
        return mode == ARMode::replaying;
    }

    void startRecording() {
        if (isRecording()) {
            log("ModState#startRecording", "WARN: already recording");
            return;
        }
        getNet().server_SendMsg("Starting to record match.");

        mode = ARMode::recording;
        currentRecording = MatchRecording();
        currentRecording.start();
        hasRecording = true;
    }

    void stopRecording() {
        if (!isRecording()) {
            log("ModState#stopRecording", "WARN: not actually recording");
            return;
        }
        getNet().server_SendMsg("Stopping recording.");

        mode = ARMode::idle;
        currentRecording.end();
    }

    void saveRecording() {
        if (!hasRecording) {
            log("ModState#saveRecording", "WARN: don't have a current recording");
            return;
        }
        else if (isRecording()) {
            stopRecording();
        }
        getNet().server_SendMsg("Saving current recording...");

        // Set in onInit
        string sessionName = getRules().get_string("AR session name");
        // Set in onRestart
        int matchNumber = getRules().get_u16("AR match number");
        int recordingNumber = getRules().get_u16("AR recording number");

        string saveFile = sessionName + "_match" + matchNumber + "recording" + recordingNumber + ".cfg";
        log("ModState#saveRecording", "Save file is: " + saveFile);
        getNet().server_SendMsg("Saving to: " + saveFile);
        string matchString = currentRecording.serialize();

        log("ModState#saveRecording", "Writing to save file...");
        ConfigFile cfg();
        cfg.add_string("data", matchString);
        cfg.saveFile(saveFile);
        getRules().set_u16("AR recording number", recordingNumber+1);
        log("ModState#saveRecording", "Done!");
    }

    void startReplaying() {
        if (isReplaying()) {
            getNet().server_SendMsg("Already replaying!");
            return;
        }
        else if (autorecord) {
            getNet().server_SendMsg("Can't replay while in autorecord mode");
            return;
        }
        getNet().server_SendMsg("Starting to replay");

        mode = ARMode::replaying;
        currentReplay = MatchReplay(currentRecording);
        currentReplay.start();
    }

    void stopReplaying() {
        if (!isReplaying()) {
            log("ModState#stopReplaying", "WARN: not actually replaying");
            return;
        }
        getNet().server_SendMsg("Stopping replay.");

        mode = ARMode::idle;
        LoadMap(currentReplay.match.mapName);
    }

    // Should be called every tick if not in idle mode
    void update() {
        //log("ModState#update", "Updating");

        if (mode == ARMode::recording) {
            currentRecording.recordTick();
        }
        else if (mode == ARMode::replaying) {
            if (currentReplay.isFinished()) {
                //log("ModState#update", "Looping current replay");
                currentReplay.start();
            }
            else {
                currentReplay.update();
            }
        }
    }

    void debug() {
        log("ModState#debug", "mode: " + mode);
    }
}


/* Represents a recording of a match.
 * This could be just a part of a match, or the whole thing.
 */
class MatchRecording {
    BlobMeta[]      allBlobMeta; // BlobMeta for all blobs that appear in the match
    BlobData[][]    recording;   // Contains an array of BlobData for every game tick
    dictionary      saves;       // maps string save names like 'before i died' to rec times
    u32             initT;       // the rec time at which the mod started recording
    u32             endT = 0;    // the rec time at the which the mod stopped recording
    string          mapName;

    int getNumSaves() {
        return saves.getSize();
    }

    u32 getNumRecordedTicks() {
        return recording.length();
    }

    // Should be called to start the recording
    void start() {
        log("MatchRecording#start", "Starting recording.");
        initT = getGameTime();
        mapName = getMap().getMapName();

        // Init blob meta
        CBlob@[] allBlobs;
        getBlobs(allBlobs);

        for (int i=0; i < allBlobs.length; i++) {
            CBlob@ blob = allBlobs[i];
            if (shouldRecordBlob_(blob)) {
                log("MatchRecording#start", "Creating blob meta for " + blob.getNetworkID());
                addBlobMeta(blob);
            }
        }
    }

    // Should be called to end the recording
    void end() {
        endT = getGameTime();
    }

    void recordTick() {
        //log("MatchRecording#recordTick", "called");
        CBlob@[] allBlobs;
        getBlobs(allBlobs);
        BlobData[] tickRecording;

        for (int i=0; i < allBlobs.length; i++) {
            CBlob@ blob = allBlobs[i];

            if (shouldRecordBlob_(blob)) {
                BlobData bd(blob);
                
                // New blob found
                if (getBlobMeta(bd.netid) is null) {
                    addBlobMeta(blob);
                }

                //bd.debug();
                tickRecording.push_back(bd);
            }
        }

        recording.push_back(tickRecording);
    }

    void createSavePoint(string saveName) {
        log("MatchRecording#createSavePoint", "Creating " + saveName);
        log("MatchRecording#createSavePoint", "NOT IMPLEMENTED YET");
    }

    // Turns the recording into a string for saving
    string serialize() {
        log("MatchRecording#serialize", "Serializing match recording...");
        string result = "<matchrecording>";

        result += "<version>" + AR_RECORDING_VERSION + "</version>";
        result += "<initT>" + initT + "</initT>";
        result += "<endT>" + endT + "</endT>";
        result += "<mapname>" + mapName + "</mapname>";

        result += "<allblobmeta>";
        for (int i=0; i < allBlobMeta.length(); i++) {
            result += allBlobMeta[i].serialize();
        }
        result += "</allblobmeta>";

        result += "<recording>";
        for (int i=0; i < recording.length(); i++) {
            BlobData[] tickData = recording[i];
            result += "<tick>";

            for (int j=0; j < tickData.length(); j++) {
                result += tickData[j].serialize();
            }
            result += "</tick>";
        }
        result += "</recording>";

        result += "</matchrecording>";
        return result;
    }

    void debug() {
        log("MatchRecording#debug", "num recorded ticks: " + getNumRecordedTicks() +
                ", num saves: " + getNumSaves() +
                ", initT: " + initT +
                ", endT: " + endT);
    }

    BlobMeta@ getBlobMeta(u16 netid) {
        // Returns the saved BlobMeta object for a blob with the given id
        // or null if it isn't saved
        for (int i=0; i < allBlobMeta.length(); i++) {
            BlobMeta meta = allBlobMeta[i];
            if (meta.netid == netid) {
                return @meta;
            }
        }

        return null;
    }

    void addBlobMeta(CBlob@ blob) {
        log("MatchRecording#addBlobMeta", "Adding blob meta for " + blob.getName() + " (" + blob.getNetworkID() + ")");
        BlobMeta meta(blob);
        meta.debug();
        allBlobMeta.push_back(meta);
    }

    // Returns true/false whether the given blob should be recorded
    // Currently only will record player
    bool shouldRecordBlob_(CBlob@ blob) {
        return blob.getPlayer() !is null;
    }
}


/* The state of a match replay
 */
class MatchReplay {
    u32 fakeT = 0;
    dictionary recToSimIDs; // maps recorded blob network ids to their ids in the current simulation
    MatchRecording match;

    MatchReplay(MatchRecording _match) {
        match = _match;
    }

    void update() {
        fakeT++;
        replayTick_();
    }

    bool isFinished() {
        return fakeT >= match.recording.length() - 1;
    }

    void debug() {
        log("MatchReplay#debug", "fakeT: " + fakeT);
    }

    // Starts the replay
    void start() {
        log("MatchReplay#start", "Rewinding");
        if (match.recording.length() == 0) {
            log("MatchReplay#start", "ERROR no recorded data");
            return;
        }

        // Kill everything in the current simulation
        AllSpec();
        KillAllBlobs();

        fakeT = 0;
        recToSimIDs.deleteAll();
        replayTick_();
    }

    void replayTick_() {
        if (fakeT >= match.recording.length()) {
            log("MatchReplay#replayTick_", "fakeT exceeds match time");
            return;
        }

        BlobData[] tickRecording = match.recording[fakeT];

        for (int i=0; i < tickRecording.length(); i++) {
            BlobData datum = tickRecording[i];
            BlobMeta@ meta = match.getBlobMeta(datum.netid);

            if (meta is null) {
                log("MatchRecording#replayTick_", "ERROR blob meta couldn't be found for datum:");
                datum.debug();
                return;
            }

            // Detect if the blob is currently alive in the simulation
            u32 simID;
            bool exists = recToSimIDs.get(""+datum.netid, simID);

            if (!exists) {
                //log("MatchRecording#replayTick_", "Blob doesn't exist in sim yet so creating it");
                CBlob@ blob = spawnBlob_(meta, datum);

                if (blob is null) {
                    log("MatchRecording#replayTick_", "ERROR probably couldn't create blob");
                    datum.debug();
                    meta.debug();
                }
                else {
                    recToSimIDs.set(""+datum.netid, blob.getNetworkID());
                    replayBlob_(blob, datum);
                }
            }
            else {
                CBlob@ blob = getBlobByNetworkID(simID);
                if (blob is null) {
                    log("MatchRecording#replayTick_", "WARN blob has entry in recToSimIDs but does not exist in game.");
                }
                else {
                    replayBlob_(blob, datum);
                }
            }
        }
    }

    void replayBlob_(CBlob@ blob, BlobData datum) {
        if ((datum.position - blob.getPosition()).Length() > AR_RUBBERBAND_SNAP) {
            // Snap blob to recorded position if it strays too far
            blob.setPosition(datum.position);
        }
        blob.setAimPos(datum.aimPos);

        for (int i=0; i < AR_ALL_KEYS.length; i++) {
            keys k = AR_ALL_KEYS[i];
            if (k & datum.keys > 0)
                blob.setKeyPressed(k, true);
            else
                blob.setKeyPressed(k, false);
        }
    }

    CBlob@ spawnBlob_(BlobMeta@ meta, BlobData datum) {
        if (meta.name == "knight" || meta.name == "archer" || meta.name == "builder") {
            // Set sex and head appropriately
            CBlob@ blob = server_CreateBlobNoInit(meta.name);
            blob.server_setTeamNum(meta.teamNum);
            blob.setPosition(datum.position);
            blob.setHeadNum(meta.headNum);
            blob.setSexNum(meta.sexNum);
            blob.Init();
            return blob;
        }
        else {
            CBlob@ blob = server_CreateBlob(meta.name, meta.teamNum, datum.position);
            return blob;
        }
    }

}


/* Information about a blob that should not change over time.
 */
class BlobMeta {
    u16     netid;
    string  name;
    int     teamNum;
    u16     playerid                = 0;
    string  playerUsername;
    string  playerCharacterName;
    int     sexNum;
    int     headNum;

    BlobMeta(CBlob@ blob) {
        netid   = blob.getNetworkID();
        name    = blob.getName();
        teamNum = blob.getTeamNum();
        sexNum  = blob.getSexNum();
        headNum = blob.getHeadNum();

        CPlayer@ player = blob.getPlayer();
        if (player !is null) {
            playerid = player.getNetworkID();
            playerUsername = player.getUsername();
            playerCharacterName = player.getCharacterName();
        }
    }

    bool hasPlayer() {
        return playerid != 0;
    }

    string serialize() {
        string result = "<blobmeta>";

        result += "<netid>" + netid + "</netid>";
        result += "<name>" + name + "</name>";
        result += "<teamNum>" + teamNum + "</teamNum>";
        result += "<sexNum>" + sexNum + "</sexNum>";
        result += "<headNum>" + headNum + "</headNum>";

        if (hasPlayer()) {
            result += "<playerid>" + playerid + "</playerid>";
            result += "<playerusername>" + playerUsername + "</playerusername>";
            result += "<playercharname>" + playerCharacterName + "</playercharname>";
        }

        result += "</blobmeta>";

        return result;
    }

    void debug() {
        log("BlobMeta#debug", "netid: " + netid +
                ", name: " + name + 
                ", teamNum: " + teamNum +
                ", playerid: " + playerid +
                ", playerUsername: " + playerUsername +
                ", playerCharacterName: " + playerCharacterName);
    }
}


/* Information about a blob to be recorded on every tick
 */
class BlobData {
    u16     netid;
    Vec2f   position;
    Vec2f   aimPos;
    uint16  keys;
    float   health;

    BlobData(CBlob@ blob) {
        netid = blob.getNetworkID();
        position = blob.getPosition();
        MovementVars@ vars = blob.getMovement().getVars();
        aimPos = vars.aimpos;
        keys = vars.keys;
        health = blob.getHealth();
    }

    string serialize() {
        string result = "<blobdata>";

        result += "<netid>" + netid + "</netid>";
        result += "<position>" + position.x + "," + position.y + "</position>";
        result += "<aimpos>" + aimPos.x + "," + aimPos.y + "</aimpos>";
        result += "<keys>" + keys + "</keys>";
        result += "<health>" + health + "</health>";

        result += "</blobdata>";

        return result;
    }

    void debug() {
        log("BlobData#debug", "netid: " + netid +
                ", position: " + stringVec2f(position) + 
                ", aimPos: " + stringVec2f(aimPos) +
                ", keys: " + keys +
                ", health: " + health);
    }
}


// Globals
ModState STATE();

// Hooks
void onInit(CRules@ this) {
    this.set_string("AR session name", "session" + XORRandom(1000000)); // used to give a name to each match's save file
    this.set_u16("AR match number", 0); // used to give a name to each match's save file
    this.set_u16("AR recording number", 0);
}

void onTick(CRules@ this) {
    STATE.update();
}

void onRestart(CRules@ this) {
    this.set_u16("AR match number", this.get_u16("AR match number") + 1);

    if (STATE.autorecord) {
        getNet().server_SendMsg("autorecord kicking in!");
        STATE.startRecording();
    }
}

void onStateChange(CRules@ this, const u8 oldState) {
    // Detect game over
    if (this.getCurrentState() == GAME_OVER &&
            oldState != GAME_OVER) {
        if (STATE.autorecord) {
            getNet().server_SendMsg("Game over detected - autorecord saving match!");
            // Last match was being recorded so save it
            STATE.stopRecording();
            STATE.saveRecording();
        }
    }
}

bool onServerProcessChat(CRules@ this, const string& in text_in, string& out text_out, CPlayer@ player)
{
	if (player is null || !player.isMod()) {
		return true;
    }

    string[]@ tokens = text_in.split(" ");
    int tl = tokens.length;

    if (tl > 0) {
        if (tokens[0] == "!autorecord") {
            // enabling autorecord makes the mod automatically record matches when they start, and saves them when they finish
            log("onServerProcessChat", "autorecord command received");
            HandleAutoRecordCmd();
        }
        else if (tokens[0] == "!stopautorecord") {
            // enabling autorecord makes the mod automatically record matches when they start, and saves them when they finish
            log("onServerProcessChat", "stopautorecord command received");
            HandleStopAutoRecordCmd();
        }
        else if (tokens[0] == "!record") {
            log("onServerProcessChat", "record command received");
            HandleRecordCmd();
        }
        else if (tokens[0] == "!stoprecording") {
            log("onServerProcessChat", "stoprecording command received");
            HandleStopRecordingCmd();
        }
        else if (tokens[0] == "!replay") {
            log("onServerProcessChat", "replay command received");
            HandleReplayCmd();
        }
        else if (tokens[0] == "!stopreplay") {
            log("onServerProcessChat", "stopreplay command received");
            HandleStopReplayCmd();
        }
        else if (tokens[0] == "!save") {
            log("onServerProcessChat", "save command received");
            HandleSaveCmd();
        }
        else if (tokens[0] == "!allspec") {
            log("onServerProcessChat", "allspec command received");
            AllSpec();
        }
    }

    return true;
}

void HandleAutoRecordCmd() {
    log("HandleAutoRecordCmd", "Called");
    if (STATE.isRecording()) {
        STATE.stopRecording();
    }
    else if (STATE.isReplaying()) {
        STATE.stopReplaying();
    }

    getNet().server_SendMsg("Enabling autorecord!");
    STATE.autorecord = true;
    LoadNextMap();
}

void HandleStopAutoRecordCmd() {
    log("HandleStopAutoRecordCmd", "Called");
    if (!STATE.autorecord) {
        getNet().server_SendMsg("Not actually in autorecord mode.");
    }

    getNet().server_SendMsg("Stopping autorecord.");
    STATE.autorecord = false;
}

void HandleRecordCmd() {
    log("HandleRecordCmd", "Called");
    if (STATE.isRecording()) {
        getNet().server_SendMsg("Already recording!");
    }
    else {
        STATE.startRecording();
    }
}

void HandleStopRecordingCmd() {
    log("HandleStopRecordingCmd", "Called");
    if (!STATE.isRecording()) {
        getNet().server_SendMsg("Not actually recording!");
    }
    else {
        STATE.stopRecording();
    }
}

void HandleReplayCmd() {
    log("HandleReplayCmd", "Called");
    if (STATE.isReplaying()) {
        getNet().server_SendMsg("Already replaying!");
    }
    else {
        STATE.startReplaying();
    }
}

void HandleStopReplayCmd() {
    log("HandleStopReplayCmd", "Called");
    if (!STATE.isReplaying()) {
        getNet().server_SendMsg("Not actually replaying!");
    }
    else {
        STATE.stopReplaying();
    }
}

void HandleSaveCmd() {
    if (!STATE.hasRecording) {
        getNet().server_SendMsg("No replay to save!");
    }
    else {
        STATE.saveRecording();
    }
}

/// Helpers
string stringVec2f(Vec2f v) {
    return "Vec2f(" + v.x + ", " + v.y + ")";
}

void ForceToSpectate(CRules@ this, CPlayer@ player) {
    RulesCore@ core;
    this.get("core", @core);

    core.ChangePlayerTeam(player, this.getSpectatorTeamNum());
}

void AllSpec() {
    CRules@ rules = getRules();
    for (int i=0; i < getPlayerCount(); i++) {
        CPlayer@ player = getPlayer(i);
        if (player.getTeamNum() != rules.getSpectatorTeamNum()) {
            ForceToSpectate(rules, player);
        }
    }
}

void KillAllBlobs() {
    //log("KillAllBlobs", "Killing everything! Yay!");
    CBlob@[] allBlobs;
    getBlobs(allBlobs);

    for (int i=0; i < allBlobs.length(); i++) {
        CBlob@ blob = allBlobs[i];
        if (blob.getName() == "knight" || blob.getName() == "archer") {
            blob.server_Die();
        }
    }
}
