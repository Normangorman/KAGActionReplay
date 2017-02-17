// This script is used for recording/replaying games.
// Class methods or functions ending in _ are considered private.
#define SERVER_ONLY

#include "Logging.as";
#include "RulesCore.as";
#include "XMLParser.as";
#include "KnightCommon.as";


const int    AR_RECORDING_VERSION = 2;   // the version number for the file format. If the format changes this should be changed.
const string AR_RECORDING_DIRECTORY = "../Cache"; // the directory where recording files are loaded from.
const float  AR_POS_RUBBERBAND_SNAP   = 4.0; // If a blob's position strays more than this amount from it's recorded value then it will be moved.
const float  AR_VEL_RUBBERBAND_SNAP   = 0.2; // If a blob's velocity strays more than this amount from it's recorded value then it will be moved.
const bool   AR_ENABLE_KNIGHT_SPECIFIC_DATA = true;
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
    idle = 0,
    recording,
    replaying,
    // in autorecording mode, whenever a game starts a new recording will be started.
    // when a game enters game over state, the recording will be saved.
    autorecording,
    // in autoreplaying mode, all recordings with a certain name prefix are played sequentially
    // the name prefix is in ModState.
    autoreplaying
}


// The current state of the mod; whether it is recording or replaying etc.
class ModState {
    ARMode          mode;             // the current mode
    bool            hasRecording;     // whether we have a currentRecording
    MatchRecording  currentRecording;
    bool            hasReplay;        // whether we have a currentReplay
    MatchReplay     currentReplay;
    string          autoreplayMatchPrefix; // if the matches are named 'tournamentmatch0.cfg', 'tournamentmatch1.cfg' etc. then this is 'tournamentmatch'
    int             autoreplayCurrentMatch; // the number of the currently replaying match
    int             autoreplayMaxMatch;

    ModState() {
        mode = ARMode::idle;
    }

    void startRecording() {
        if (mode == ARMode::recording) {
            ServerMsg("Already recording!");
            return;
        }
        else if (mode != ARMode::idle) {
            ServerMsg("Can't start recording, already in state " + modeToString_(mode));
            return;
        }
        ServerMsg("Starting to record.");

        mode = ARMode::recording;
        newRecording_();
    }

    void stopRecording() {
        if (mode != ARMode::recording) {
            ServerMsg("Not currently recording.");
            return;
        }

        ServerMsg("Stopping recording.");
        mode = ARMode::idle;
        currentRecording.end();
    }

    void startReplaying() {
        if (mode == ARMode::replaying) {
            ServerMsg("Already replaying!");
            return;
        }
        else if (mode != ARMode::idle) {
            ServerMsg("Can't start replaying, already in state " + modeToString_(mode));
            return;
        }
        else if (!hasRecording) {
            ServerMsg("No current recording to replay.");
            return;
        }

        ServerMsg("Starting replay.");
        mode = ARMode::replaying;
        currentReplay = MatchReplay(@currentRecording);
        currentReplay.start();
        hasReplay = true;
    }

    void stopReplaying() {
        if (mode != ARMode::replaying) {
            ServerMsg("Not currently replaying.");
            return;
        }

        ServerMsg("Stopping replay.");
        mode = ARMode::idle;
        hasReplay = false;
        LoadMap(currentReplay.match.mapName);
    }

    void startAutorecording() {
        if (mode == ARMode::autorecording) {
            ServerMsg("Already autorecording!");
            return;
        }
        else if (mode != ARMode::idle) {
            ServerMsg("Can't start autorecording, already in state " + modeToString_(mode));
            return;
        }

        ServerMsg("Autorecording activated.");
        mode = ARMode::autorecording;
        hasRecording = false;
    }

    void stopAutorecording() {
        if (mode != ARMode::autorecording) {
            ServerMsg("Not currently autorecording.");
            return;
        }

        ServerMsg("Stopping autorecording.");
        mode = ARMode::idle;

        if (hasRecording) {
            currentRecording.end();
        }
    }

    void startAutoreplaying(string matchPrefix, int maxMatch) {
        if (mode == ARMode::autoreplaying) {
            ServerMsg("Already autoreplaying!");
            return;
        }
        else if (mode != ARMode::idle) {
            ServerMsg("Can't start autoreplaying, already in state " + modeToString_(mode));
            return;
        }

        ServerMsg("Autoreplaying activated.");
        mode = ARMode::autoreplaying;
        autoreplayMatchPrefix = matchPrefix;
        autoreplayCurrentMatch = 0;
        autoreplayMaxMatch = maxMatch;
        hasReplay = false;

        playNextAutoreplayMatch_();
    }

    void stopAutoreplaying() {
        if (mode != ARMode::autoreplaying) {
            ServerMsg("Not currently autoreplaying.");
            return;
        }

        ServerMsg("Stopping autoreplaying.");
        mode = ARMode::idle;

        if (hasReplay) {
            LoadMap(currentReplay.match.mapName);
        }
        hasReplay = false;
    }

    void saveRecording() {
        if (!hasRecording) {
            ServerMsg("No current recording to save.");
            return;
        }

        if (!currentRecording.ended) {
            currentRecording.end();
        }

        string saveFile = getSaveFileName_();
        ServerMsg("Saving current recording to " + saveFile);
        string matchString = currentRecording.serialize();
        ConfigFile cfg();
        cfg.add_string("data", matchString);
        bool success = cfg.saveFile(saveFile);
        if (!success) {
            ServerMsg("Error saving file.");
        }
        else {
            ServerMsg("Saved successfully.");
        }
    }

    void onTick() {
        if (mode == ARMode::recording || mode == ARMode::autorecording) {
            currentRecording.recordTick();
        }
        else if (mode == ARMode::replaying) {
            if (currentReplay.isFinished()) {
                ServerMsg("Looping current replay");
                currentReplay.start();
            }
            else {
                currentReplay.update();
            }
        }
        else if (mode == ARMode::autoreplaying) {
            if (currentReplay.isFinished()) {
                ServerMsg("Loading next replay");
                playNextAutoreplayMatch_();
            }
            else {
                currentReplay.update();
            }
        }
    }

    void onRestart() {
        if (mode == ARMode::autorecording) {
            ServerMsg("Autorecording is enabled. Starting to record the match.");
            newRecording_();
        }
    }

    void onGameOver() {
        if (mode == ARMode::autorecording) {
            if (hasRecording) {
                ServerMsg("Autorecording is enabled. Saving the current recording.");
                currentRecording.end();
                saveRecording();
            }
            else {
                ServerMsg("Autorecording is enabled but there's no current recording.");
            }
        }
        else if (mode == ARMode::autoreplaying) {
            playNextAutoreplayMatch_();
        }
    }

    void debug() {
        log("ModState#debug", "mode: " + modeToString_(mode));
    }

    void playNextAutoreplayMatch_() {
        for (int i=autoreplayCurrentMatch+1; i < autoreplayMaxMatch; i++) {
            string fileName = autoreplayMatchPrefix + i + ".cfg";
            string filePath = AR_RECORDING_DIRECTORY + "/" + fileName;

            log("ModState#playNextAutoreplayMatch_", "Next file is " + filePath);

            MatchRecording match();
            bool success = match.loadFromFile(filePath);

            if (!success) {
                continue;
            }
            else {
                hasReplay = true;
                currentReplay = MatchReplay(@match);
                currentReplay.start();
                autoreplayCurrentMatch = i;
                return;
            }
        }

        ServerMsg("No more matches.");
        stopAutoreplaying();
    }

    void newRecording_() {
        currentRecording = MatchRecording();
        currentRecording.start();
        hasRecording = true;
    }

    string getSaveFileName_() {
        string sessionName = getRules().get_string("AR session name"); // Set in onInit
        int matchNumber = getRules().get_u16("AR match number"); // Set in onRestart
        int recordingNumber = getRules().get_u16("AR recording number");
        getRules().set_u16("AR recording number", recordingNumber+1); // increment for next time

        string saveFile = sessionName + "_match" + matchNumber + "recording" + recordingNumber + ".cfg";
        return saveFile;
    }

    string modeToString_(u8 mode) {
        switch (mode) {
            case ARMode::idle:
                return "idle";
            case ARMode::recording:
                return "recording";
            case ARMode::replaying:
                return "replaying";
            case ARMode::autorecording:
                return "autorecording";
            case ARMode::autoreplaying:
                return "autoreplaying";
            default:
                log("ModState#debug", "ERROR: invalid mode " + mode);
                break;
        }

        return "INVALID MODE";
    }
}


// Represents a recording of a match. Could be all of it or just part of it.
class MatchRecording {
    BlobMeta[]      allBlobMeta; // BlobMeta for all blobs that appear in the match
    BlobData[][]    recording;   // Contains an array of BlobData for every game tick
    u32             initT;       // the rec time at which the mod started recording
    u32             endT;    // the rec time at the which the mod stopped recording
    string          mapName;
    int             winningTeam;
    bool            ended; // whether end() has been called. this value is not serialzied

    MatchRecording() {
        endT = 0;
        ended = false;
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
                addBlobMeta_(blob);
            }
        }
    }

    // Should be called to end the recording
    void end() {
        ended = true;
        endT = getGameTime();

        if (getRules().getCurrentState() == GAME_OVER) {
            winningTeam = getRules().getTeamWon();
        }
        else {
            winningTeam = -1;
        }
    }

    void recordTick() {
        //log("MatchRecording#recordTick", "called");
        if (ended) {
            log("MatchRecording#recordTick", "Recording is ended so refusing to record tick.");
            return;
        }

        CBlob@[] allBlobs;
        getBlobs(allBlobs);
        BlobData[] tickRecording;

        for (int i=0; i < allBlobs.length; i++) {
            CBlob@ blob = allBlobs[i];

            if (shouldRecordBlob_(blob)) {
                BlobData bd(blob);

                // New blob found
                if (getBlobMeta(bd.netid) is null) {
                    addBlobMeta_(blob);
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

    void debug() {
        log("MatchRecording#debug", "num recorded ticks: " + getNumRecordedTicks() +
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

    // Turns the recording into a string for saving
    string serialize() {
        log("MatchRecording#serialize", "Serializing match recording...");
        string result = "<matchrecording>";

        result += "<version>" + AR_RECORDING_VERSION + "</version>";
        result += "<initt>" + initT + "</initt>";
        result += "<endt>" + endT + "</endt>";
        result += "<mapname>" + mapName + "</mapname>";
        result += "<winningteam>" + winningTeam + "</winningteam>";

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

    bool loadFromFile(string filePath) {
        log("MatchRecording#loadFromFile", "Trying to load from " + filePath);
        ConfigFile cfg();
        bool check = cfg.loadFile(filePath);
        if (!check) {
            log("MatchRecording#loadFromFile", "Cfg couldn't load " + filePath);
            return false;
        }

        string data = cfg.read_string("data");
        if (data.length() == 0) {
            log("MatchRecording#loadFromFile", "file data is empty");
            return false;
        }

        return deserialize(data);
    }

    bool deserialize(string data) {
        log("MatchRecording#deserialize", "Beginning deserialization...");
        XMLParser parser(data);
        XMLDocument@ doc = parser.parse();

        if (doc is null || doc.root is null || doc.root.name != "matchrecording") {
            log("MatchRecording#deserialize", "Invalid data.");
            return false;
        }

        XMLElement@ el; // current element

        @el = doc.root.getFirstChild("version");
        if (el is null) { return deserializeFailure_("version"); }
        if (parseInt(el.value) != AR_RECORDING_VERSION) {
            log("MatchRecording#deserialize", "WARN Trying to load from an old recording format");
        }

        @el = doc.root.getFirstChild("initt");
        if (el is null) { return deserializeFailure_("initt"); }
        initT = parseInt(el.value);

        @el = doc.root.getFirstChild("endt");
        if (el is null) { return deserializeFailure_("endt"); }
        endT = parseInt(el.value);

        @el = doc.root.getFirstChild("mapname");
        if (el is null) { return deserializeFailure_("mapname"); }
        mapName = el.value;

        XMLElement@ el_allblobmeta = doc.root.getFirstChild("allblobmeta");
        if (el_allblobmeta is null) { return deserializeFailure_("allblobmeta"); }

        for (int i=0; i < el_allblobmeta.children.length(); i++) {
            XMLElement@ el_blobmeta = el_allblobmeta.children[i];
            if (el_blobmeta is null) { return deserializeFailure_("blobmeta"); }

            BlobMeta meta();
            @el = el_blobmeta.getFirstChild("netid");
            if (el is null) { return deserializeFailure_("netid"); }
            meta.netid = parseInt(el.value);

            @el = el_blobmeta.getFirstChild("name");
            if (el is null) { return deserializeFailure_("name"); }
            meta.name = el.value;

            @el = el_blobmeta.getFirstChild("teamnum");
            if (el is null) { return deserializeFailure_("teamnum"); }
            meta.teamNum = parseInt(el.value);

            @el = el_blobmeta.getFirstChild("sexnum");
            if (el is null) { return deserializeFailure_("sexnum"); }
            meta.sexNum = parseInt(el.value);

            @el = el_blobmeta.getFirstChild("headnum");
            if (el is null) { return deserializeFailure_("sexnum"); }
            meta.sexNum = parseInt(el.value);

            @el = el_blobmeta.getFirstChild("playerid");
            if (el is null) { return deserializeFailure_("playerid"); }
            meta.playerid = parseInt(el.value);

            @el = el_blobmeta.getFirstChild("playerusername");
            if (el is null) { return deserializeFailure_("playerusername"); }
            meta.playerUsername = parseInt(el.value);

            @el = el_blobmeta.getFirstChild("playercharname");
            if (el is null) { return deserializeFailure_("playercharname"); }
            meta.playerCharacterName = parseInt(el.value);

            allBlobMeta.push_back(meta);
        }

        XMLElement@ el_recording = doc.root.getFirstChild("recording");
        if (el_recording is null) { return deserializeFailure_("recording"); }

        for (int i=0; i < el_recording.children.length(); i++) {
            XMLElement@ el_tick = el_recording.children[i];
            if (el_tick is null) { return deserializeFailure_("tick"); }

            BlobData[] tick;

            for (int j=0; j < el_tick.children.length(); j++) {
                XMLElement@ el_blobdata = el_tick.children[j];
                if (el_blobdata is null) { return deserializeFailure_("blobdata"); }

                BlobData bd();
                @el = el_blobdata.getFirstChild("netid");
                if (el is null) { return deserializeFailure_("netid"); }
                bd.netid = parseInt(el.value);

                @el = el_blobdata.getFirstChild("position");
                if (el is null) { return deserializeFailure_("position"); }
                string[]@ positionParts = el.value.split(",");
                if (positionParts.length() != 2) {
                    log("MatchRecording#deserialize", "Incorrect number of position parts: " + positionParts.length());
                    return false;
                }
                bd.position = Vec2f(parseFloat(positionParts[0]), parseFloat(positionParts[1]));

                @el = el_blobdata.getFirstChild("velocity");
                if (el is null) { return deserializeFailure_("velocity"); }
                string[]@ velocityParts = el.value.split(",");
                if (velocityParts.length() != 2) {
                    log("MatchRecording#deserialize", "Incorrect number of velocity parts: " + velocityParts.length());
                    return false;
                }
                bd.velocity = Vec2f(parseFloat(velocityParts[0]), parseFloat(velocityParts[1]));

                @el = el_blobdata.getFirstChild("aimpos");
                if (el is null) { return deserializeFailure_("aimpos"); }
                string[]@ aimposParts = el.value.split(",");
                if (aimposParts.length() != 2) {
                    log("MatchRecording#deserialize", "Incorrect number of aimpos parts: " + aimposParts.length());
                    return false;
                }
                bd.aimPos = Vec2f(parseFloat(aimposParts[0]), parseFloat(aimposParts[1]));

                @el = el_blobdata.getFirstChild("keys");
                if (el is null) { return deserializeFailure_("keys"); }
                bd.keys = parseInt(el.value);

                @el = el_blobdata.getFirstChild("health");
                if (el is null) { return deserializeFailure_("health"); }
                bd.health = parseFloat(el.value);

                tick.push_back(bd);
            }

            recording.push_back(tick);
        }

        log("MatchRecording#deserialize", "Deserialization successful!");
        return true;
    }

    bool deserializeFailure_(string tagName) {
        log("MatchRecording#deserialize", "Deserialization failed: missing element " + tagName);
        return false;
    }

    void addBlobMeta_(CBlob@ blob) {
        log("MatchRecording#addBlobMeta_", "Adding blob meta for " + blob.getName() + " (" + blob.getNetworkID() + ")");
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
    u32 replayT = 0;
    dictionary recToSimIDs; // maps recorded blob network ids to their ids in the current simulation
    MatchRecording@ match;

    MatchReplay(MatchRecording@ _match) {
        @match = _match;
    }

    void update() {
        if (getMap().getMapName() != match.mapName) {
            log("MatchReplay#update", "ERROR current map doesn't match the map of the recording");
            return;
        }
        replayT++;
        replayTick_();
    }

    bool isFinished() {
        return replayT >= match.recording.length() - 1;
    }

    void debug() {
        log("MatchReplay#debug", "replayT: " + replayT);
    }

    // Starts the replay
    void start() {
        log("MatchReplay#start", "Rewinding");
        if (match.recording.length() == 0) {
            log("MatchReplay#start", "ERROR no recorded data");
            return;
        }

        AllSpec();

        if (getMap().getMapName() == match.mapName) {
            KillAllBlobs();
        }
        else {
            LoadMap(match.mapName);
        }

        replayT = 0;
        recToSimIDs.deleteAll();
        replayTick_();
    }

    void replayTick_() {
        if (replayT >= match.recording.length()) {
            log("MatchReplay#replayTick_", "replayT exceeds match time");
            return;
        }

        BlobData[] tickRecording = match.recording[replayT];

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
        // Snap blob to recorded position if it strays too far
        if ((datum.position - blob.getPosition()).Length() > AR_POS_RUBBERBAND_SNAP) {
            blob.setPosition(datum.position);
        }
        // Snap blob velocity to recorded velocity if it strays too far
        if ((datum.velocity - blob.getVelocity()).Length() > AR_VEL_RUBBERBAND_SNAP) {
            blob.setVelocity(datum.velocity);
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


// Information about a blob that should not change over time.
class BlobMeta {
    u16     netid;
    string  name;
    int     teamNum;
    u16     playerid;
    string  playerUsername;
    string  playerCharacterName;
    int     sexNum;
    int     headNum;

    BlobMeta() {
        // For when loading from a file
        playerid = 0;
    }

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
        else {
            playerid = 0;
        }
    }

    bool hasPlayer() {
        return playerid != 0;
    }

    string serialize() {
        string result = "<blobmeta>";

        result += "<netid>" + netid + "</netid>";
        result += "<name>" + name + "</name>";
        result += "<teamnum>" + teamNum + "</teamnum>";
        result += "<sexnum>" + sexNum + "</sexnum>";
        result += "<headnum>" + headNum + "</headnum>";

        if (hasPlayer()) {
            result += "<playerid>" + playerid + "</playerid>";
            result += "<playerusername>" + playerUsername + "</playerusername>";
            result += "<playercharname>" + playerCharacterName + "</playercharname>";
        }

        result += "</blobmeta>";

        return result;
    }

    void debug() {
        log("BlobMeta#debug", serialize());
    }
}


/* Information about a blob to be recorded on every tick
 */
class BlobData {
    u16     netid;
    Vec2f   position;
    Vec2f   velocity;
    Vec2f   aimPos;
    uint16  keys;
    float   health;
    // Knight specific stuff
    bool    useKnightData = false;
    u8      knocked;
    u8      knightState;
    u8      swordTimer;
    u8      shieldTimer;
    bool    doubleSlash;
    u32     slideTime;
    u32     shieldDown;

    BlobData() {} // for when loading from a file

    BlobData(CBlob@ blob) {
        netid = blob.getNetworkID();
        position = blob.getPosition();
        velocity = blob.getVelocity();
        MovementVars@ vars = blob.getMovement().getVars();
        aimPos = vars.aimpos;
        keys = vars.keys;
        health = blob.getHealth();

        if (AR_ENABLE_KNIGHT_SPECIFIC_DATA && blob.getName() == "knight") {
            useKnightData = true;
            KnightInfo@ knight;
            bool exists = blob.get("knightInfo", @knight);
            if (!exists) {
                log("BlobData", "ERROR couldn't get knightInfo from knight");
                return;
            }
            knocked = blob.get_u8("knocked");
            knightState = knight.state;
            swordTimer = knight.swordTimer;
            shieldTimer = knight.shieldTimer;
            doubleSlash = knight.doubleslash;
            slideTime = knight.slideTime;
            shieldDown = knight.shield_down;
        }
    }

    string serialize() {
        string result = "<blobdata>";

        result += "<netid>" + netid + "</netid>";
        result += "<position>" + position.x + "," + position.y + "</position>";
        result += "<velocity>" + velocity.x + "," + velocity.y + "</velocity>";
        result += "<aimpos>" + aimPos.x + "," + aimPos.y + "</aimpos>";
        result += "<keys>" + keys + "</keys>";
        result += "<health>" + health + "</health>";

        if (useKnightData) {
            result += "<knocked>" + knocked + "</knocked>";
            result += "<knightstate>" + knightState + "</knightstate>";
            result += "<swordtimer>" + swordTimer + "</swordtimer>";
            result += "<shieldtimer>" + shieldTimer + "</shieldtimer>";
            result += "<doubleslash>" + doubleSlash + "</doubleslash>";
            result += "<slidetime>" + slideTime + "</slidetime>";
            result += "<shielddown>" + shieldDown + "</shielddown>";
        }

        result += "</blobdata>";

        return result;
    }

    void debug() {
        log("BlobData#debug", serialize());
    }
}


// Globals
ModState STATE();

// Hooks
void onReload(CRules@ this) {
    //XMLTests();
}

void onInit(CRules@ this) {
    // Putting these properties in the Rules rather than the ModState means that the mod can be rebuilt without
    // losing the information.
    this.set_string("AR session name", "session" + XORRandom(1000000)); // used to give a name to each match's save file
    this.set_u16("AR match number", 0); // used to give a name to each match's save file
    this.set_u16("AR recording number", 0);
}

void onTick(CRules@ this) {
    STATE.onTick();
}

void onRestart(CRules@ this) {
    this.set_u16("AR match number", this.get_u16("AR match number") + 1);
    STATE.onRestart();
}

void onStateChange(CRules@ this, const u8 oldState) {
    if (this.getCurrentState() == GAME_OVER && oldState != GAME_OVER) {
        STATE.onGameOver();
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
            STATE.startAutorecording();
        }
        else if (tokens[0] == "!stopautorecord") {
            // enabling autorecord makes the mod automatically record matches when they start, and saves them when they finish
            log("onServerProcessChat", "stopautorecord command received");
            STATE.stopAutorecording();
        }
        if (tokens[0] == "!autoreplay") {
            // enabling autorecord makes the mod automatically record matches when they start, and saves them when they finish
            log("onServerProcessChat", "autoreplay command received");
            STATE.startAutoreplaying("match", 100);
        }
        else if (tokens[0] == "!stopautoreplay") {
            // enabling autorecord makes the mod automatically record matches when they start, and saves them when they finish
            log("onServerProcessChat", "stopautoplay command received");
            STATE.stopAutoreplaying();
        }
        else if (tokens[0] == "!record") {
            log("onServerProcessChat", "record command received");
            STATE.startRecording();
        }
        else if (tokens[0] == "!stoprecording") {
            log("onServerProcessChat", "stoprecording command received");
            STATE.stopRecording();
        }
        else if (tokens[0] == "!replay") {
            log("onServerProcessChat", "replay command received");
            STATE.startReplaying();
        }
        else if (tokens[0] == "!stopreplay") {
            log("onServerProcessChat", "stopreplay command received");
            STATE.stopReplaying();
        }
        else if (tokens[0] == "!save") {
            log("onServerProcessChat", "save command received");
            STATE.saveRecording();
        }
        else if (tokens[0] == "!allspec") {
            log("onServerProcessChat", "allspec command received");
            AllSpec();
        }
    }

    return true;
}

// Helpers
string stringVec2f(Vec2f v) {
    return "Vec2f(" + v.x + ", " + v.y + ")";
}

void ServerMsg(string msg) {
    getNet().server_SendMsg("ActionReplay: " + msg);
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

bool StringCheck(string str, int i, string sub) {
    // Returns true/false if the given string contains a substring 'sub' starting at index i
    if (str.length() < sub.length()) {
        log("stringCheck", "WARN str.length < sub.length");
        return false;
    }

    string strSub = str.substr(i, sub.length());
    /*
    log("stringCheck", "i = " + i +
            ", str.length = " + str.length() +
            ", sub = " + sub +
            ", i+sub.length = " + i + sub.length() +
            ", strSub = " + strSub
            );
            */
    return strSub == sub;
}
