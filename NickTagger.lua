local ADDON_NAME = ...

local defaults = {
    enabled = true,
    nickname = nil, -- will be player name by default (first time)
    showGreeting = true, -- show "Loaded..." message on login
    enabledChannels = {
        SAY           = false,
        YELL          = false,
        EMOTE         = false,
        WHISPER       = false,
        BN_WHISPER    = false,
        PARTY         = true,
        RAID          = true,
        INSTANCE_CHAT = false,
        GUILD         = false,
        OFFICER       = false,
        CHANNEL       = false, -- General/Trade/LocalDefense/Newcomer/etc.
        COMMUNITIES_CHANNEL = false,
    },
}

local NickTaggerOptionsCategory -- reserved for Settings API if needed
local NickTagger_Initialized = false -- to avoid UI updating before DB is ready

local CHANNEL_OPTIONS = {
    { key = "SAY",                 label = "Say (/s)", aliases = { "say", "s" } },
    { key = "YELL",                label = "Yell (/y)", aliases = { "yell", "y" } },
    { key = "EMOTE",               label = "Emote (/e)", aliases = { "emote", "e", "me" } },
    { key = "WHISPER",             label = "Whisper (/w)", aliases = { "whisper", "w", "tell", "msg" } },
    { key = "BN_WHISPER",          label = "Battle.net Whisper", aliases = { "bn", "bnw", "bnwhisper", "battle", "battle.net" } },
    { key = "PARTY",               label = "Party (/p)", aliases = { "party", "group", "p" } },
    { key = "RAID",                label = "Raid (/raid)", aliases = { "raid", "r" } },
    { key = "INSTANCE_CHAT",       label = "Instance (/i)", aliases = { "instance", "inst", "i", "instance_chat" } },
    { key = "GUILD",               label = "Guild (/g)", aliases = { "guild", "g" } },
    { key = "OFFICER",             label = "Officer (/o)", aliases = { "officer", "o" } },
    { key = "CHANNEL",             label = "Public channels (/1, /2: Trade/General/Newcomer/etc.)", aliases = { "channel", "channels", "ch", "public", "trade", "general", "newcomer" } },
    { key = "COMMUNITIES_CHANNEL", label = "Communities", aliases = { "community", "communities", "comm" } },
}

local CHANNEL_ALIAS_TO_KEY = {}
local CHANNEL_LABEL_BY_KEY = {}
local CHANNEL_HELP_NAMES = {}

for _, option in ipairs(CHANNEL_OPTIONS) do
    CHANNEL_LABEL_BY_KEY[option.key] = option.label
    table.insert(CHANNEL_HELP_NAMES, option.aliases[1])
    for _, alias in ipairs(option.aliases) do
        CHANNEL_ALIAS_TO_KEY[alias] = option.key
    end
end

table.sort(CHANNEL_HELP_NAMES)

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[NickTagger]|r " .. tostring(msg))
end

-- Merge table "src" into "dst" (only missing keys)
local function MergeDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then
                dst[k] = {}
            end
            MergeDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function IsChannelEnabled(chatType)
    if not NickTaggerDB.enabled then
        return false
    end
    if not chatType then
        return false
    end
    return NickTaggerDB.enabledChannels[chatType] == true
end

local function NormalizeChannelName(name)
    if not name then return nil end
    return CHANNEL_ALIAS_TO_KEY[name:lower()]
end

local function NickTagger_ApplyPrefix(editBox, userInput)
    if not editBox or editBox:IsForbidden() then
        return
    end

    local text = editBox:GetText()
    if not userInput or not text or text == "" then
        return
    end

    if editBox.NickTagger_ApplyingPrefix then
        return
    end

    -- Do not touch slash commands
    if text:sub(1, 1) == "/" then
        return
    end

    local chatType = editBox:GetAttribute("chatType") or "SAY"
    if not IsChannelEnabled(chatType) then
        return
    end

    local nick = NickTaggerDB.nickname
    if not nick or nick == "" then
        return
    end

    -- Avoid duplicate prefix
    local escapedNick = nick:gsub("(%W)", "%%%1")
    local pattern = "^%[" .. escapedNick .. "%]"
    if text:match(pattern) then
        return
    end

    editBox.NickTagger_ApplyingPrefix = true
    editBox:SetText(string.format("[%s] %s", nick, text))
    editBox:SetCursorPosition(editBox:GetNumLetters())
    editBox.NickTagger_ApplyingPrefix = false
end

-- Slash command handler
local function HandleSlashCommand(msg)
    msg = msg or ""
    msg = msg:match("^%s*(.-)%s*$") -- trim

    if msg == "" then
        Print("Commands:")
        Print("/nicktag nick <text>  - set nickname")
        Print("/nicktag on|off      - enable/disable addon")
        Print("/nicktag enable <channel>  - enable chat type")
        Print("/nicktag disable <channel> - disable channel")
        Print("/nicktag status      - show current settings")
        Print("Channels: " .. table.concat(CHANNEL_HELP_NAMES, ", "))
        return
    end

    local cmd, rest = msg:match("^(%S+)%s*(.*)$")
    cmd = cmd:lower()

    if cmd == "nick" then
        if rest == "" then
            Print("Current nickname: " .. (NickTaggerDB.nickname or "none"))
        else
            NickTaggerDB.nickname = rest
            Print("Nickname set to: " .. rest)
        end

    elseif cmd == "on" or cmd == "enableaddon" then
        NickTaggerDB.enabled = true
        Print("Addon enabled.")

    elseif cmd == "off" or cmd == "disableaddon" then
        NickTaggerDB.enabled = false
        Print("Addon disabled.")

    elseif cmd == "enable" or cmd == "disable" then
        local chanName = rest:match("^(%S+)")
        if not chanName then
            Print("Usage: /nicktag " .. cmd .. " <channel>")
            return
        end

        local chatType = NormalizeChannelName(chanName)
        if not chatType then
            Print("Unknown channel: " .. chanName .. ". Use: " .. table.concat(CHANNEL_HELP_NAMES, ", "))
            return
        end

        local value = (cmd == "enable")
        NickTaggerDB.enabledChannels[chatType] = value

        Print(string.format("%s channel %s",
            value and "Enabled" or "Disabled",
            CHANNEL_LABEL_BY_KEY[chatType] or chatType))

    elseif cmd == "status" then
        Print("Enabled: " .. tostring(NickTaggerDB.enabled))
        Print("Nickname: " .. (NickTaggerDB.nickname or "none"))
        local list = {}
        for k, v in pairs(NickTaggerDB.enabledChannels) do
            table.insert(list, string.format("%s=%s", k, v and "ON" or "off"))
        end
        table.sort(list)
        Print("Channels: " .. table.concat(list, ", "))
    else
        Print("Unknown command. Type /nicktag for help.")
    end
end

-- Create Settings UI panel
local function NickTagger_CreateOptionsPanel()
    local frame = CreateFrame("Frame", "NickTaggerOptionsFrame", UIParent)
    frame.name = "NickTagger"

    local scrollFrame = CreateFrame("ScrollFrame", "NickTaggerOptionsScrollFrame", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 8, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(560, 1400)
    scrollFrame:SetScrollChild(content)

    -- Title
    local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("NickTagger")

    -- Description
    local subtext = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtext:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtext:SetWidth(500)
    subtext:SetText("Adds a custom nickname prefix to your chat messages, e.g. [timurchak] Привет, in selected channels.")

    -- Enable checkbox
    local enableCB = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    enableCB:SetPoint("TOPLEFT", subtext, "BOTTOMLEFT", 0, -12)
    enableCB:SetScript("OnClick", function(self)
        NickTaggerDB.enabled = self:GetChecked() and true or false
    end)
    enableCB:SetScript("OnShow", function(self)
        self:SetChecked(NickTaggerDB.enabled)
    end)

    local enableLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    enableLabel:SetPoint("LEFT", enableCB, "RIGHT", 4, 1)
    enableLabel:SetText("Enable NickTagger")

    -- "Hide greeting" checkbox
    local hideGreetingCB = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    hideGreetingCB:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -8)
    hideGreetingCB:SetScript("OnClick", function(self)
        -- If checked => hide greeting => showGreeting = false
        NickTaggerDB.showGreeting = not self:GetChecked()
    end)
    hideGreetingCB:SetScript("OnShow", function(self)
        -- Checked when greeting is disabled
        self:SetChecked(NickTaggerDB.showGreeting == false)
    end)

    local hideGreetingLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    hideGreetingLabel:SetPoint("LEFT", hideGreetingCB, "RIGHT", 4, 1)
    hideGreetingLabel:SetText("Hide greeting message on login")

    -- Nickname label
    local nicknameLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    nicknameLabel:SetPoint("TOPLEFT", hideGreetingCB, "BOTTOMLEFT", 0, -20)
    nicknameLabel:SetText("Nickname:")

    -- Nickname edit box
    local nicknameBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    nicknameBox:SetSize(200, 20)
    nicknameBox:SetAutoFocus(false)
    nicknameBox:SetPoint("LEFT", nicknameLabel, "RIGHT", 8, 0)

    -- Apply nickname only on real user input
    nicknameBox:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then
            -- Text changed programmatically (SetText) -> не трогаем сохранённый ник
            return
        end
        if NickTagger_Initialized and NickTaggerDB then
            NickTaggerDB.nickname = self:GetText()
        end
    end)

    nicknameBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    nicknameBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        self:SetText(NickTaggerDB.nickname or UnitName("player") or "")
    end)
    nicknameBox:SetScript("OnShow", function(self)
        local text = NickTaggerDB.nickname
        if not text or text == "" then
            text = UnitName("player") or ""
        end
        self:SetText(text)
    end)

    -- Channels header
    local channelsLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    channelsLabel:SetPoint("TOPLEFT", nicknameLabel, "BOTTOMLEFT", 0, -24)
    channelsLabel:SetText("Apply prefix in channels:")

    -- Helper to create channel checkboxes
    local function CreateChannelCheckbox(anchor, offsetY, labelText, chatTypeKey)
        local cb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, offsetY)
        cb:SetScript("OnClick", function(self)
            NickTaggerDB.enabledChannels[chatTypeKey] = self:GetChecked() and true or false
        end)
        cb:SetScript("OnShow", function(self)
            self:SetChecked(NickTaggerDB.enabledChannels[chatTypeKey] == true)
        end)

        local lbl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        lbl:SetPoint("LEFT", cb, "RIGHT", 4, 1)
        lbl:SetText(labelText)

        return cb
    end

    local previousAnchor = channelsLabel
    local previousOffset = -8
    local lastCB = nil
    for _, option in ipairs(CHANNEL_OPTIONS) do
        lastCB = CreateChannelCheckbox(previousAnchor, previousOffset, option.label, option.key)
        previousAnchor = lastCB
        previousOffset = -4
    end

    -- Spacer so panel does not end too early
    local bottomSpacer = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    bottomSpacer:SetPoint("TOPLEFT", lastCB, "BOTTOMLEFT", 0, -24)
    bottomSpacer:SetText("Use /nicktag enable channel for Trade/General/Newcomer and /nicktag enable communities for Communities chat.")

    -- Register with new Settings API (Dragonflight / The War Within / 12.0+)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category, layout = Settings.RegisterCanvasLayoutCategory(frame, "NickTagger", "NickTagger")
        category.ID = "NickTagger"
        Settings.RegisterAddOnCategory(category)
        NickTaggerOptionsCategory = category
    elseif InterfaceOptions_AddCategory then
        -- Fallback for very old versions
        InterfaceOptions_AddCategory(frame)
    end
end

-- Event frame
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    -- Init DB
    if type(NickTaggerDB) ~= "table" then
        NickTaggerDB = {}
    end
    MergeDefaults(NickTaggerDB, defaults)

    if NickTaggerDB.nickname == nil then
        NickTaggerDB.nickname = UnitName("player")
    end

    -- Hook all chat edit boxes without replacing protected handlers.
    if NUM_CHAT_WINDOWS then
        for i = 1, NUM_CHAT_WINDOWS do
            local editBox = _G["ChatFrame"..i.."EditBox"]
            if editBox and not editBox.NickTagger_Hooked then
                editBox.NickTagger_Hooked = true
                editBox:HookScript("OnTextChanged", NickTagger_ApplyPrefix)
            end
        end
    end

    SLASH_NICKTAGGER1 = "/nicktag"
    SLASH_NICKTAGGER2 = "/nt"
    SlashCmdList["NICKTAGGER"] = HandleSlashCommand

    NickTagger_CreateOptionsPanel()

    NickTagger_Initialized = true

    if NickTaggerDB.showGreeting then
        Print("Loaded. Type /nicktag for options. Open via Escape -> Options -> AddOns -> NickTagger.")
    end
end)
