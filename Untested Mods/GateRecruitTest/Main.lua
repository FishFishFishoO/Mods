-- ============================================
-- Gate Recruit Test. TEST ONLY: don't upload this, it's a cheat.
--
--   F8 = one of your modded characters walks up to the sect gate right away
--        and asks to join (picked at random from the ones in the pool).
--   F7 = writes the gate recruit rules and their state to the log.
--
-- How F8 works: it briefly changes this map's gate recruit rule
-- (<map>_Recruit_2) to "modded characters only, spawn now, once", asks the
-- game to start that rule, then puts the rule back a few seconds later.
-- The character mods (gate recruiting on) must be enabled too: they're what
-- put the characters in the pool. Characters already in your world aren't
-- in the pool, so they can't be summoned twice.
--
-- The one-off rule stays in the save as a finished rule. Harmless, but test
-- on a copy of a save if you want to keep the real one untouched.
-- Log: %LOCALAPPDATA%\EasternEra\Saved\SaveGames\log.txt
-- ============================================

local Mod = {}

local KEY_SUMMON = "F8"
local KEY_REPORT = "F7"
local KEY_INTERVAL = 0.05
local RESTORE_AFTER = 5 -- seconds before the rule is put back

-- ============================================
-- Helpers
-- ============================================

local function Str(Name)
    return UE.UKismetStringLibrary.Conv_NameToString(Name)
end

local function Name(S)
    return UE.UKismetStringLibrary.Conv_StringToName(S)
end

local function FirstID(Key)
    local IDs = Key.CharacterIDs
    if IDs and IDs:Num() > 0 then
        return Str(IDs:Get(1))
    end
    return ""
end

function Mod:Log(Message)
    -- Only "error" level reliably reaches the game log.
    UE.UModLuaLibrary.ModLog(self.ModInfo.Metadata.ModId, Message, "error")
end

function Mod:GetWorld()
    local GI = UE.UGameplayStatics.GetGameInstance(self.ModInfo)
    return GI and GI:GetWorld() or nil
end

function Mod:GetTable(World)
    local GameMode = UE.UGameplayStatics.GetGameMode(World)
    if not GameMode or not GameMode.GameConfigComponent then
        return nil
    end
    local DT = GameMode.GameConfigComponent:GetGameConfigByType(UE.EGameConfigType.MonsterGenerationConfig)
    if not DT or not DT:IsValid() then
        return nil
    end
    return DT
end

function Mod:PlayerPlace(World)
    local Class = UE.UClass.Load("/Script/EastRimWorld.WorldPlace")
    if not Class then
        return nil
    end
    local Actors = UE.TArray(UE.AActor)
    UE.UGameplayStatics.GetAllActorsOfClass(World, Class, Actors)
    for i = 1, Actors:Num() do
        local Place = Actors:Get(i)
        if Place and Place.bPlayerPlace and Place.GenerateCharacterComponent then
            return Place
        end
    end
    return nil
end

local function MakeKey(KeyName)
    local Key = nil
    pcall(function()
        if UE.EKeys and UE.EKeys[KeyName] then
            Key = UE.EKeys[KeyName]
        end
    end)
    if Key == nil then
        pcall(function()
            Key = UE.FKey()
            Key.KeyName = KeyName
        end)
    end
    return Key
end

function Mod:WasKeyJustPressed(PC, KeyName)
    self._Keys = self._Keys or {}
    self._KeyDown = self._KeyDown or {}
    if not self._Keys[KeyName] then
        self._Keys[KeyName] = MakeKey(KeyName)
    end
    local ok, Down = pcall(function() return PC:IsInputKeyDown(self._Keys[KeyName]) end)
    Down = ok and Down == true
    local Was = self._KeyDown[KeyName] == true
    self._KeyDown[KeyName] = Down
    return Down and not Was
end

-- "Vagrant_101=3 LingXuan=1 ..." for every set in a TArray<FGenerationSetData>.
local function DescribeSets(Sets)
    local Parts = {}
    for s = 1, Sets:Num() do
        local Map = Sets:Get(s).GenerationData
        local Keys = Map:Keys()
        for k = 1, Keys:Num() do
            local Key = Keys:Get(k)
            table.insert(Parts, FirstID(Key) .. "=" .. tostring(Map:Find(Key)))
        end
    end
    return table.concat(Parts, " ")
end

-- ============================================
-- F7: report
-- ============================================

function Mod:Report()
    local World = self:GetWorld()
    if not World then
        return
    end
    local Place = self:PlayerPlace(World)
    if not Place then
        self:Log("F7: no player place found (load a save first)")
        return
    end
    self:Log("F7: home place = " .. Str(Place.WorldPlaceID))

    local DT = self:GetTable(World)
    if DT then
        local RowNames = UE.UDataTableFunctionLibrary.GetDataTableRowNames(DT)
        for i = 1, RowNames:Num() do
            local RowName = RowNames[i]
            if string.find(Str(RowName), "_Recruit_", 1, true) then
                local Row = UE.FMonsterGenerationConfig()
                if UE.UDataTableFunctionLibrary.GetDataTableRowFromName(DT, RowName, Row) then
                    self:Log("  table " .. Str(RowName) .. ": " .. DescribeSets(Row.GenerationSetData))
                end
            end
        end
    end

    local Queue = Place.GenerateCharacterComponent.MonsterGenerationInfoQueue
    self:Log(string.format("  running rules: %d", Queue:Num()))
    for i = 1, Queue:Num() do
        local Info = Queue:Get(i)
        local ID = Str(Info.MonsterGenerationConfig.ID)
        if string.find(ID, "Recruit", 1, true) then
            self:Log(string.format("  running %s state=%s time=%.0f pool: %s",
                ID, tostring(Info.GenerationState), Info.StateTime or -1,
                DescribeSets(Info.MonsterGenerationConfig.GenerationSetData)))
        end
    end
end

-- ============================================
-- F8: summon
-- ============================================

-- IDs of every character already in the world (in the sect or waiting at the gate).
function Mod:PresentIDs(World)
    local Present = {}
    local PC = UE.UGameplayStatics.GetPlayerController(World, 0)
    if PC and PC.GetAllCharacter then
        local Characters = UE.TArray(UE.AEastRimWorldCharacter)
        PC:GetAllCharacter(Characters)
        for i = 1, Characters:Num() do
            local C = Characters:Get(i)
            if C and C.CharacterID then
                Present[Str(C.CharacterID)] = true
            end
        end
    end
    return Present
end

-- Takes characters who are already in the world out of a row's pools.
local function DropPresent(Row, Present)
    local Sets = Row.GenerationSetData
    for s = 1, Sets:Num() do
        local Set = Sets:Get(s)
        local Map = Set.GenerationData
        local Keys = Map:Keys()
        local Changed = false
        for k = 1, Keys:Num() do
            local Key = Keys:Get(k)
            if Present[FirstID(Key)] then
                Map:Remove(Key)
                Changed = true
            end
        end
        if Changed then
            Sets:Set(s, Set)
        end
    end
end

function Mod:Summon()
    local World = self:GetWorld()
    if not World then
        return
    end
    local DT = self:GetTable(World)
    local Place = self:PlayerPlace(World)
    if not DT or not Place then
        self:Log("F8: game not ready (load a save first)")
        return
    end
    if self._Restore then
        self:Log("F8: still restoring the last summon, try again in a few seconds")
        return
    end

    local PlaceID = Str(Place.WorldPlaceID)
    local RowName = Name(PlaceID .. "_Recruit_2")
    local Row = UE.FMonsterGenerationConfig()
    if not UE.UDataTableFunctionLibrary.GetDataTableRowFromName(DT, RowName, Row) then
        self:Log("F8: no gate recruit rule for this map (" .. PlaceID .. "_Recruit_2). Press F7 and send the log.")
        return
    end
    local Original = UE.FMonsterGenerationConfig()
    UE.UDataTableFunctionLibrary.GetDataTableRowFromName(DT, RowName, Original)

    -- Keep only the modded characters who aren't already in your world.
    local Present = self:PresentIDs(World)
    local Sets = Row.GenerationSetData
    local Left = {}
    for s = 1, Sets:Num() do
        local Set = Sets:Get(s)
        local Map = Set.GenerationData
        local Keys = Map:Keys()
        for k = 1, Keys:Num() do
            local Key = Keys:Get(k)
            local ID = FirstID(Key)
            if string.sub(ID, 1, 8) == "Vagrant_" or Present[ID] then
                Map:Remove(Key)
            else
                table.insert(Left, ID)
            end
        end
        Sets:Set(s, Set)
    end
    if #Left == 0 then
        self:Log("F8: no modded characters in the pool. Either no character mod is enabled, " ..
            "or they're all already in your world.")
        return
    end

    -- Spawn now, once, no conditions.
    local Rule = Row.GenerationRule
    Rule.GenerationRule = UE.EGenerationRuleType.Fixed
    Row.GenerationRule = Rule
    Row.GenerationCondition:Clear()
    Row.Condition:Clear()
    Row.bActivateCheckCondition = false
    Row.ActivateCountDown = 1
    Row.GenerationDelay = 0
    Row.GenerationTimes = 1
    Row.GenerationMaxNumber = 1
    Row.ID = Name(PlaceID .. "_Recruit_2")

    if not UE.UModLuaLibrary.ReplaceDataTableRow(DT, RowName, Row) then
        self:Log("F8: couldn't change the rule")
        return
    end

    local Component = Place.GenerateCharacterComponent
    local Before = Component.MonsterGenerationInfoQueue:Num()
    local ok, err = pcall(function() Component:CreateGenerationByIDWithTime(RowName, 0) end)
    local After = Component.MonsterGenerationInfoQueue:Num()
    self:Log(string.format("F8: summoning one of [%s] at %s: %s (running rules %d -> %d)",
        table.concat(Left, ", "), PlaceID, ok and "started" or ("failed: " .. tostring(err)), Before, After))

    -- Put the real rule back once the game has made its copy.
    self._Restore = UE.UModLuaLibrary.RegisterModRepeatingTimer(nil, RESTORE_AFTER, true, function()
        local Id = self._Restore
        self._Restore = nil
        if Id then
            pcall(function() UE.UModLuaLibrary.UnregisterModRepeatingTimer(Id) end)
        end
        -- Anyone who joined meanwhile stays out of the restored pool.
        pcall(function() DropPresent(Original, self:PresentIDs(World)) end)
        if UE.UModLuaLibrary.ReplaceDataTableRow(DT, RowName, Original) then
            self:Log("F8: rule restored")
        else
            self:Log("F8: couldn't restore the rule (reload the save to reset it)")
        end
    end)
end

-- ============================================
-- Lifecycle
-- ============================================

function Mod:CheckKeys()
    local World = self:GetWorld()
    if not World then
        return
    end
    local PC = UE.UGameplayStatics.GetPlayerController(World, 0)
    if not PC then
        return
    end
    if self:WasKeyJustPressed(PC, KEY_SUMMON) then
        local ok, err = pcall(function() self:Summon() end)
        if not ok then
            self:Log("F8 error: " .. tostring(err))
        end
    end
    if self:WasKeyJustPressed(PC, KEY_REPORT) then
        local ok, err = pcall(function() self:Report() end)
        if not ok then
            self:Log("F7 error: " .. tostring(err))
        end
    end
end

function Mod:OnModLoaded()
    self:Log("Gate Recruit Test loaded: F8 = summon a modded character to the gate, F7 = report")
    self._KeyTimer = UE.UModLuaLibrary.RegisterModRepeatingTimer(nil, KEY_INTERVAL, true, function()
        self:CheckKeys()
    end)
end

function Mod:OnModUnloaded()
    for _, Id in ipairs({ self._KeyTimer, self._Restore }) do
        pcall(function() UE.UModLuaLibrary.UnregisterModRepeatingTimer(Id) end)
    end
    self._KeyTimer, self._Restore = nil, nil
end

return Mod
