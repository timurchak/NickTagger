local ADDON_NAME = ...

-- Per-profile default settings
local profileDefaults = {
    enabled = true,
    nickname = nil, -- will be player name by default (first time)
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

-- Global defaults (showGreeting is global; profiles/characterProfiles are new)
local defaults = {
    showGreeting = true,
    profiles = {
        ["Default"] = profileDefaults,
    },
    characterProfiles = {},
}

local NickTaggerOptionsCategory -- reserved for Settings API if needed
local NickTagger_Initialized = false -- to avoid UI updating before DB is ready
local NickTagger_InMythicContent = false -- suspend during M+ to avoid SecretValue taint

local MYTHIC_KEYSTONE_DIFFICULTY = 8
local MYTHIC_RAID_DIFFICULTY = 16

local function IsRestrictedContent()
    local _, _, difficultyID = GetInstanceInfo()
    return difficultyID == MYTHIC_KEYSTONE_DIFFICULTY or difficultyID == MYTHIC_RAID_DIFFICULTY
end

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

-- Deep copy a table
local function CopyTable(t)
    local copy = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            copy[k] = CopyTable(v)
        else
            copy[k] = v
        end
    end
    return copy
end

-- ── Profile helpers ───────────────────────────────────────────────────────────

local function GetCharKey()
    return (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "Unknown")
end

local function GetActiveProfileName()
    if not NickTaggerDB or not NickTaggerDB.characterProfiles then return "Default" end
    return NickTaggerDB.characterProfiles[GetCharKey()] or "Default"
end

local function GetCurrentProfile()
    if not NickTaggerDB or not NickTaggerDB.profiles then return {} end
    local name = GetActiveProfileName()
    return NickTaggerDB.profiles[name] or NickTaggerDB.profiles["Default"] or {}
end

-- Migrate old schema (pre-1.1.0) to new profiles schema
local function MigrateOldSchema()
    -- Old schema had enabled/nickname/enabledChannels at root level
    if NickTaggerDB.enabledChannels ~= nil then
        if not NickTaggerDB.profiles then
            NickTaggerDB.profiles = {}
        end
        if not NickTaggerDB.profiles["Default"] then
            NickTaggerDB.profiles["Default"] = {}
        end
        local profile = NickTaggerDB.profiles["Default"]
        if profile.enabled == nil then
            profile.enabled = NickTaggerDB.enabled
        end
        if profile.nickname == nil then
            profile.nickname = NickTaggerDB.nickname
        end
        if profile.enabledChannels == nil then
            profile.enabledChannels = NickTaggerDB.enabledChannels
        end
        -- Remove old root-level keys
        NickTaggerDB.enabled = nil
        NickTaggerDB.nickname = nil
        NickTaggerDB.enabledChannels = nil
        Print("Settings migrated to Default profile.")
    end
end

local function IsChannelEnabled(chatType)
    local profile = GetCurrentProfile()
    if not profile.enabled then
        return false
    end
    if not chatType then
        return false
    end
    return profile.enabledChannels and profile.enabledChannels[chatType] == true
end

local function NormalizeChannelName(name)
    if not name then return nil end
    return CHANNEL_ALIAS_TO_KEY[name:lower()]
end

-- ── Profile management ────────────────────────────────────────────────────────

local function GetSortedProfileNames()
    local names = {}
    for name in pairs(NickTaggerDB.profiles) do
        table.insert(names, name)
    end
    table.sort(names, function(a, b)
        if a == "Default" then return true end
        if b == "Default" then return false end
        return a < b
    end)
    return names
end

-- UI refresh callbacks registered by the options panel
local uiRefreshFuncs = {}

local function RefreshProfileUI()
    for _, fn in ipairs(uiRefreshFuncs) do
        pcall(fn)
    end
end

local function CreateProfile(name)
    name = name:match("^%s*(.-)%s*$") -- trim
    if not name or name == "" then
        Print("Profile name cannot be empty.")
        return false
    end
    if NickTaggerDB.profiles[name] then
        Print("Profile '" .. name .. "' already exists.")
        return false
    end
    -- Copy current profile settings and fill any missing defaults
    local newProfile = CopyTable(GetCurrentProfile())
    MergeDefaults(newProfile, profileDefaults)
    NickTaggerDB.profiles[name] = newProfile
    Print("Profile '" .. name .. "' created.")
    return true
end

local function DeleteProfile(name)
    if name == "Default" then
        Print("Cannot delete the Default profile.")
        return false
    end
    if not NickTaggerDB.profiles[name] then
        Print("Profile '" .. name .. "' does not exist.")
        return false
    end
    NickTaggerDB.profiles[name] = nil
    -- Switch all characters using this profile back to Default
    for charKey, profileName in pairs(NickTaggerDB.characterProfiles) do
        if profileName == name then
            NickTaggerDB.characterProfiles[charKey] = "Default"
        end
    end
    Print("Profile '" .. name .. "' deleted.")
    return true
end

local function UseProfile(name)
    if not NickTaggerDB.profiles[name] then
        Print("Profile '" .. name .. "' does not exist.")
        return false
    end
    NickTaggerDB.characterProfiles[GetCharKey()] = name
    Print("Now using profile '" .. name .. "'.")
    RefreshProfileUI()
    return true
end

-- ── Prefix application ────────────────────────────────────────────────────────

local function NickTagger_ApplyPrefix(editBox, userInput)
    if NickTagger_InMythicContent then
        return
    end

    if not editBox or editBox:IsForbidden() or InCombatLockdown() then
        return
    end

    local ok, text = pcall(editBox.GetText, editBox)
    if not ok then
        return
    end
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

    local nick = GetCurrentProfile().nickname
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

-- ── Slash command handler ─────────────────────────────────────────────────────

local function HandleSlashCommand(msg)
    msg = msg or ""
    msg = msg:match("^%s*(.-)%s*$") -- trim

    if msg == "" then
        Print("Commands:")
        Print("/nicktag nick <text>           - set nickname for current profile")
        Print("/nicktag on|off                - enable/disable current profile")
        Print("/nicktag enable <channel>      - enable channel in current profile")
        Print("/nicktag disable <channel>     - disable channel in current profile")
        Print("/nicktag status                - show current settings")
        Print("/nicktag profile list          - list all profiles")
        Print("/nicktag profile create <name> - create new profile (copies current)")
        Print("/nicktag profile delete <name> - delete a profile")
        Print("/nicktag profile use <name>    - use profile for this character")
        Print("/nicktag profile current       - show active profile name")
        Print("Channels: " .. table.concat(CHANNEL_HELP_NAMES, ", "))
        return
    end

    local cmd, rest = msg:match("^(%S+)%s*(.*)$")
    cmd = cmd:lower()

    local profile = GetCurrentProfile()

    if cmd == "nick" then
        if rest == "" then
            Print("Current nickname: " .. (profile.nickname or "none") ..
                  " (profile: " .. GetActiveProfileName() .. ")")
        else
            profile.nickname = rest
            Print("Nickname set to: " .. rest)
        end

    elseif cmd == "on" or cmd == "enableaddon" then
        profile.enabled = true
        Print("Addon enabled (profile: " .. GetActiveProfileName() .. ").")

    elseif cmd == "off" or cmd == "disableaddon" then
        profile.enabled = false
        Print("Addon disabled (profile: " .. GetActiveProfileName() .. ").")

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
        profile.enabledChannels[chatType] = value

        Print(string.format("%s channel %s (profile: %s)",
            value and "Enabled" or "Disabled",
            CHANNEL_LABEL_BY_KEY[chatType] or chatType,
            GetActiveProfileName()))

    elseif cmd == "status" then
        Print("Active profile: " .. GetActiveProfileName())
        Print("Enabled: " .. tostring(profile.enabled))
        Print("Nickname: " .. (profile.nickname or "none"))
        local list = {}
        for k, v in pairs(profile.enabledChannels) do
            table.insert(list, string.format("%s=%s", k, v and "ON" or "off"))
        end
        table.sort(list)
        Print("Channels: " .. table.concat(list, ", "))

    elseif cmd == "profile" then
        local subcmd, subrest = rest:match("^(%S+)%s*(.*)$")
        if not subcmd then
            Print("Profile commands: list, create <name>, delete <name>, use <name>, current")
            return
        end
        subcmd = subcmd:lower()

        if subcmd == "list" then
            local names = GetSortedProfileNames()
            local active = GetActiveProfileName()
            Print("Profiles (" .. #names .. "):")
            for _, name in ipairs(names) do
                local marker = (name == active) and " |cff00ff00<-- active|r" or ""
                Print("  " .. name .. marker)
            end

        elseif subcmd == "create" then
            if subrest == "" then
                Print("Usage: /nicktag profile create <name>")
                return
            end
            if CreateProfile(subrest) then
                RefreshProfileUI()
            end

        elseif subcmd == "delete" then
            if subrest == "" then
                Print("Usage: /nicktag profile delete <name>")
                return
            end
            if DeleteProfile(subrest) then
                RefreshProfileUI()
            end

        elseif subcmd == "use" or subcmd == "select" then
            if subrest == "" then
                Print("Usage: /nicktag profile use <name>")
                return
            end
            UseProfile(subrest)

        elseif subcmd == "current" then
            Print("Current profile: " .. GetActiveProfileName())

        else
            Print("Unknown profile command. Use: list, create <name>, delete <name>, use <name>, current")
        end

    else
        Print("Unknown command. Type /nicktag for help.")
    end
end

-- ── Options UI panel ──────────────────────────────────────────────────────────

local function NickTagger_CreateOptionsPanel()
    local frame = CreateFrame("Frame", "NickTaggerOptionsFrame", UIParent)
    frame.name = "NickTagger"

    local scrollFrame = CreateFrame("ScrollFrame", "NickTaggerOptionsScrollFrame", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 8, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(560, 1600)
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

    -- ── Profile section ───────────────────────────────────────────────────────

    local profileHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    profileHeader:SetPoint("TOPLEFT", subtext, "BOTTOMLEFT", 0, -20)
    profileHeader:SetText("Profile:")

    -- Dropdown to select active profile
    local profileDropdown = CreateFrame("Frame", "NickTaggerProfileDropdown", content, "UIDropDownMenuTemplate")
    profileDropdown:SetPoint("TOPLEFT", profileHeader, "BOTTOMLEFT", -15, -4)
    UIDropDownMenu_SetWidth(profileDropdown, 160)

    local function ProfileDropdownInit(self, level)
        local names = GetSortedProfileNames()
        local active = GetActiveProfileName()
        for _, name in ipairs(names) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = name
            info.checked = (name == active)
            info.func = function()
                UseProfile(name)
                UIDropDownMenu_SetText(profileDropdown, name)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end

    UIDropDownMenu_Initialize(profileDropdown, ProfileDropdownInit)
    UIDropDownMenu_SetText(profileDropdown, GetActiveProfileName())

    table.insert(uiRefreshFuncs, function()
        UIDropDownMenu_SetText(profileDropdown, GetActiveProfileName())
        UIDropDownMenu_Initialize(profileDropdown, ProfileDropdownInit)
    end)

    -- New profile name input
    local newProfileLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    newProfileLabel:SetPoint("TOPLEFT", profileDropdown, "BOTTOMLEFT", 15, -8)
    newProfileLabel:SetText("New profile:")

    local newProfileBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    newProfileBox:SetSize(150, 20)
    newProfileBox:SetAutoFocus(false)
    newProfileBox:SetPoint("LEFT", newProfileLabel, "RIGHT", 8, 0)
    newProfileBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    newProfileBox:SetScript("OnEscapePressed", function(self) self:SetText("") self:ClearFocus() end)

    local createBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    createBtn:SetSize(70, 22)
    createBtn:SetPoint("LEFT", newProfileBox, "RIGHT", 6, 0)
    createBtn:SetText("Create")
    createBtn:SetScript("OnClick", function()
        local name = newProfileBox:GetText():match("^%s*(.-)%s*$")
        if name ~= "" then
            if CreateProfile(name) then
                newProfileBox:SetText("")
                RefreshProfileUI()
            end
        else
            Print("Enter a profile name first.")
        end
    end)

    -- Delete current profile button
    local deleteBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    deleteBtn:SetSize(110, 22)
    deleteBtn:SetPoint("LEFT", createBtn, "RIGHT", 6, 0)
    deleteBtn:SetText("Delete profile")
    deleteBtn:SetScript("OnClick", function()
        if DeleteProfile(GetActiveProfileName()) then
            RefreshProfileUI()
        end
    end)

    local function UpdateDeleteBtn()
        deleteBtn:SetEnabled(GetActiveProfileName() ~= "Default")
    end
    deleteBtn:SetScript("OnShow", UpdateDeleteBtn)
    table.insert(uiRefreshFuncs, UpdateDeleteBtn)

    -- Separator line
    local sep = content:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.5, 0.5, 0.5, 0.5)
    sep:SetSize(520, 1)
    sep:SetPoint("TOPLEFT", newProfileLabel, "BOTTOMLEFT", 0, -14)

    -- ── Per-profile settings ──────────────────────────────────────────────────

    -- Enable checkbox
    local enableCB = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    enableCB:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -12)
    enableCB:SetScript("OnClick", function(self)
        GetCurrentProfile().enabled = self:GetChecked() and true or false
    end)
    enableCB:SetScript("OnShow", function(self)
        self:SetChecked(GetCurrentProfile().enabled)
    end)
    table.insert(uiRefreshFuncs, function()
        enableCB:SetChecked(GetCurrentProfile().enabled)
    end)

    local enableLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    enableLabel:SetPoint("LEFT", enableCB, "RIGHT", 4, 1)
    enableLabel:SetText("Enable NickTagger")

    -- "Hide greeting" checkbox (global, not per-profile)
    local hideGreetingCB = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    hideGreetingCB:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -8)
    hideGreetingCB:SetScript("OnClick", function(self)
        NickTaggerDB.showGreeting = not self:GetChecked()
    end)
    hideGreetingCB:SetScript("OnShow", function(self)
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

    nicknameBox:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        if NickTagger_Initialized and NickTaggerDB then
            GetCurrentProfile().nickname = self:GetText()
        end
    end)
    nicknameBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    nicknameBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        local profile = GetCurrentProfile()
        self:SetText(profile.nickname or UnitName("player") or "")
    end)
    nicknameBox:SetScript("OnShow", function(self)
        local profile = GetCurrentProfile()
        local text = profile.nickname
        if not text or text == "" then
            text = UnitName("player") or ""
        end
        self:SetText(text)
    end)
    table.insert(uiRefreshFuncs, function()
        local profile = GetCurrentProfile()
        local text = profile.nickname
        if not text or text == "" then
            text = UnitName("player") or ""
        end
        nicknameBox:SetText(text)
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
            local p = GetCurrentProfile()
            if p.enabledChannels then
                p.enabledChannels[chatTypeKey] = self:GetChecked() and true or false
            end
        end)
        cb:SetScript("OnShow", function(self)
            local p = GetCurrentProfile()
            self:SetChecked(p.enabledChannels and p.enabledChannels[chatTypeKey] == true)
        end)
        table.insert(uiRefreshFuncs, function()
            local p = GetCurrentProfile()
            cb:SetChecked(p.enabledChannels and p.enabledChannels[chatTypeKey] == true)
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

    -- Bottom hint
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

-- ── Event handling ────────────────────────────────────────────────────────────

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHALLENGE_MODE_START")
f:RegisterEvent("CHALLENGE_MODE_COMPLETED")
f:RegisterEvent("CHALLENGE_MODE_RESET")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:SetScript("OnEvent", function(self, event)
    if event == "CHALLENGE_MODE_START" then
        NickTagger_InMythicContent = true
        return
    end
    if event == "CHALLENGE_MODE_COMPLETED" or event == "CHALLENGE_MODE_RESET" then
        NickTagger_InMythicContent = false
        return
    end
    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        NickTagger_InMythicContent = IsRestrictedContent()
        return
    end

    -- Init DB
    if type(NickTaggerDB) ~= "table" then
        NickTaggerDB = {}
    end

    -- Migrate old schema BEFORE applying defaults (preserves existing data)
    MigrateOldSchema()

    -- Fill in any missing keys with defaults
    MergeDefaults(NickTaggerDB, defaults)

    -- Ensure Default profile has a nickname
    local defaultProfile = NickTaggerDB.profiles["Default"]
    if defaultProfile and defaultProfile.nickname == nil then
        defaultProfile.nickname = UnitName("player")
    end

    -- Register this character in characterProfiles if not already set
    local charKey = GetCharKey()
    if not NickTaggerDB.characterProfiles[charKey] then
        NickTaggerDB.characterProfiles[charKey] = "Default"
    end

    -- Hook all chat edit boxes without replacing protected handlers
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
        Print(string.format("Loaded. Profile: %s. Type /nicktag for options.", GetActiveProfileName()))
    end
end)
