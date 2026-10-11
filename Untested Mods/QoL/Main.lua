-- ============================================
-- QoL: quality-of-life changes in one mod. Every part can be switched off below.
--
--  1. Build & demolish times: construction 1.5x faster, deconstruction 2x faster.
--     Not instant: builders still haul materials and do the work.
--  2. Order hotkeys. Select something, press the key, and the mod clicks the
--     matching button on the selection panel for you (same as clicking it).
--       G = Cut                     (trees, bushes, plants)
--       K = Harvest / Collect / Mine
--       L = Cancel order
--       O = Priority execution      (this target goes first among jobs of its type)
--     The game already has: U = Cancel Construct, C = Deconstruct, B = Copy Building.
--  3. Demolish first: a building marked for deconstruction also gets Priority
--     Execution, so it comes down before other work.
--  4. Hide disciple names over characters. F9 toggles it.
--  5. Bigger batches: sticks and Jade Bricks make twice as many per batch.
--  6. Long-lasting fuel: wood-burning buildings burn wood half as fast.
--  7. Sturdier buildings: twice the durability.
--  8. More fragments: adventures give 3x martial arts fragments (45-120 instead of 15-40).
--
-- Edits DT_Buildconfig, DT_FormulaData and DT_ApprenticeshipReward in memory only.
-- Nothing is written to the save. Safe to run repeatedly: always works from the
-- original values, never stacks.
--
-- Replaces the separate BuildTimes, QoLMods, SectComforts and MoreFragments mods.
-- Don't run those (or FastBuild) alongside this one: they edit the same numbers.
-- ============================================

local Mod = {}

-- ===== Config =====
-- Set any multiplier to 1 (or a switch to false) to turn that part off.

-- 1. Build & demolish times. 1 = vanilla, 1.5 = 50% faster, 2 = twice as fast.
-- Values below 1 make it slower (0.5 = takes twice as long). No instant setting:
-- the lowest any building can go is 1 work point.
local BUILD_SPEED = 1.5
local DEMOLISH_SPEED = 2

-- 2. Hotkeys. Unreal key names: "G", "K", "F9", "Four", "NumPadOne", ...
-- Set a key to "" to switch that hotkey off.
local KEY_CUT = "G"
local KEY_HARVEST = "K"
local KEY_CANCEL = "L"
local KEY_PRIORITY = "O"
local KEY_TOGGLE_NAMES = "F9"

-- 3. true = deconstruct orders get Priority Execution automatically.
local DEMOLISH_FIRST = true

-- 4. true = hide names over characters when the game loads (F9 still toggles).
local HIDE_NAMES = true
-- true = also hide the title/suffix text next to the name.
local HIDE_TITLES = false

-- 5. Bigger batches: how many times more each listed recipe makes.
local BATCH_MULTIPLIER = 2
-- Vanilla: sticks 20 per 10 logs, Jade Brick 25 per 50 stone + 5 iron ore.
local BATCH_RECIPES = {
    "Formula_ChoppingBlock_1001", -- Stick (Chopping Block)
    "Formula_Smelter_1002",       -- Jade Brick (Furnace)
    -- "Formula_Smelter_1001",    -- Glazed Tiles (Furnace): remove the -- at the start to include it
}

-- 6. Long-lasting fuel: 2 = one load of wood lasts twice as long.
local FUEL_LASTS = 2
-- Fuel buildings that don't burn wood, left alone.
local FUEL_EXCLUDE = { MillStone = true, Recharge = true }

-- 7. Sturdier buildings: 2 = twice the durability.
local DURABILITY_MULTIPLIER = 2

-- 8. More fragments: 3 = 45-120 fragments per reward instead of 15-40.
local FRAGMENT_MULTIPLIER = 3

-- How often keys are checked (seconds). Lower = snappier, higher = lighter.
local KEY_INTERVAL = 0.05
-- How often demolish-first and name hiding are re-applied (seconds).
local SLOW_INTERVAL = 0.5
-- How often to retry until the game's config tables are available (seconds).
local RETRY_INTERVAL = 1.0
local MAX_RETRIES = 120

-- Button IDs from DT_CommonButton. The first visible one in each list is clicked.
local CUT_BUTTONS = { "Fell", "CutOff" }
local HARVEST_BUTTONS = { "Harvest", "HarvestFarmland", "Collect_High", "Exploitation" }
local CANCEL_BUTTONS = { "CancelOrder" }
local PRIORITY_BUTTONS = { "PriorityExecution" }
local DEMOLISH_BUTTONS = { DestoryBuilding = true, Destory_Right = true }

local BUTTON_CLASS_PATH = "/Game/Blueprints/UI/CommonUI/Buttons/W_CommonButtonBase.W_CommonButtonBase_C"
local STATEBAR_CLASS_PATH = "/Game/Blueprints/Character/StateBar/WBP_CharacterStateBar.WBP_CharacterStateBar_C"

-- Vanilla fragment reward rows, used if the reward type can't be read.
local FRAGMENT_ROWS = { Fragment_Blue = true, Fragment_Purple = true, Fragment_Orange = true }

-- Original values per row, recorded the first time each row is seen.
local OriginalBuild = {}
local OriginalBatch = {}
local OriginalFragments = {}

-- ============================================
-- Helpers
-- ============================================

function Mod:Log(Message)
    -- Only "error" level reliably reaches the game log.
    UE.UModLuaLibrary.ModLog(self.ModInfo.Metadata.ModId, Message, "error")
end

-- Logs a message only the first time it is seen, so timers can't flood the log.
function Mod:LogOnce(Tag, Message)
    self._Logged = self._Logged or {}
    if not self._Logged[Tag] then
        self._Logged[Tag] = true
        self:Log(Message)
    end
end

function Mod:GetWorld()
    local GI = UE.UGameplayStatics.GetGameInstance(self.ModInfo)
    if not GI then
        return nil
    end
    return GI:GetWorld()
end

function Mod:GetPlayerController()
    local World = self:GetWorld()
    if not World then
        return nil
    end
    return UE.UGameplayStatics.GetPlayerController(World, 0)
end

function Mod:GetConfigTable(ConfigType)
    local World = self:GetWorld()
    if not World then
        return nil
    end
    local GameMode = UE.UGameplayStatics.GetGameMode(World)
    if not GameMode or not GameMode.GameConfigComponent then
        return nil
    end
    local DT = GameMode.GameConfigComponent:GetGameConfigByType(ConfigType)
    if not DT or not DT:IsValid() then
        return nil
    end
    return DT
end

local function Round(Value)
    return math.floor(Value + 0.5)
end

local function Scaled(Original, Speed)
    if Original <= 1 or Speed <= 0 then
        return Original
    end
    return math.max(1, Round(Original / Speed))
end

-- ============================================
-- 1, 6, 7. Buildings: build/demolish times, fuel, durability (one table, one pass)
-- ============================================

function Mod:ApplyBuildings(Reason)
    local DT = self:GetConfigTable(UE.EGameConfigType.BuildConfig)
    if not DT then
        return false
    end

    local RowNames = UE.UDataTableFunctionLibrary.GetDataTableRowNames(DT)
    local Times, Fuel, Sturdy, Failed = 0, 0, 0, 0

    for i = 1, RowNames:Num() do
        local RowName = RowNames[i]
        local Name = UE.UKismetStringLibrary.Conv_NameToString(RowName)
        local Row = UE.FBuildConfigData()
        if UE.UDataTableFunctionLibrary.GetDataTableRowFromName(DT, RowName, Row) then
            if not OriginalBuild[Name] then
                OriginalBuild[Name] = {
                    Build = Row.Workload,
                    Demolish = Row.DestoryWorkload,
                    Burn = Row.OneTimeExpendFuel,
                    Durability = Row.Durability,
                }
            end
            local Orig = OriginalBuild[Name]
            local Dirty = false

            -- Build and demolish times.
            local WantBuild = Scaled(Orig.Build, BUILD_SPEED)
            local WantDemolish = Scaled(Orig.Demolish, DEMOLISH_SPEED)
            if Row.Workload ~= WantBuild or Row.DestoryWorkload ~= WantDemolish then
                Row.Workload = WantBuild
                Row.DestoryWorkload = WantDemolish
                Dirty = true
                Times = Times + 1
            end

            -- Fuel: burn less wood each time, so one load lasts longer.
            if FUEL_LASTS > 0 and Row.bNeedFuel and Orig.Burn > 0 and not FUEL_EXCLUDE[Name] then
                local WantBurn = Orig.Burn / FUEL_LASTS
                if math.abs(Row.OneTimeExpendFuel - WantBurn) > 0.0001 then
                    Row.OneTimeExpendFuel = WantBurn
                    Dirty = true
                    Fuel = Fuel + 1
                end
            end

            -- Durability: -1/0 means indestructible or unused, leave those alone.
            if Orig.Durability > 0 then
                local WantDurability = Round(Orig.Durability * DURABILITY_MULTIPLIER)
                if Row.Durability ~= WantDurability then
                    Row.Durability = WantDurability
                    Dirty = true
                    Sturdy = Sturdy + 1
                end
            end

            if Dirty and not UE.UModLuaLibrary.ReplaceDataTableRow(DT, RowName, Row) then
                Failed = Failed + 1
            end
        end
    end

    self:Log(string.format("[%s] buildings: build x%s / demolish x%s changed %d | fuel lasts x%s changed %d | durability x%s changed %d | failed %d",
        Reason, tostring(BUILD_SPEED), tostring(DEMOLISH_SPEED), Times,
        tostring(FUEL_LASTS), Fuel, tostring(DURABILITY_MULTIPLIER), Sturdy, Failed))
    return true
end

-- ============================================
-- 5. Bigger batches
-- ============================================

function Mod:ApplyBatches(Reason)
    local DT = self:GetConfigTable(UE.EGameConfigType.FormulaData)
    if not DT then
        return false
    end

    local Changed, AlreadyDone, Missing, Failed = 0, 0, 0, 0
    for _, Name in ipairs(BATCH_RECIPES) do
        local RowName = UE.UKismetStringLibrary.Conv_StringToName(Name)
        local Row = UE.FFormulaData()
        if UE.UDataTableFunctionLibrary.GetDataTableRowFromName(DT, RowName, Row) then
            if not OriginalBatch[Name] then
                OriginalBatch[Name] = Row.OutputItemNumber
            end
            local Want = math.max(1, Round(OriginalBatch[Name] * BATCH_MULTIPLIER))
            if Row.OutputItemNumber == Want then
                AlreadyDone = AlreadyDone + 1
            else
                Row.OutputItemNumber = Want
                if UE.UModLuaLibrary.ReplaceDataTableRow(DT, RowName, Row) then
                    Changed = Changed + 1
                    self:Log(string.format("%s: makes %d -> %d", Name, OriginalBatch[Name], Want))
                else
                    Failed = Failed + 1
                end
            end
        else
            Missing = Missing + 1
        end
    end

    self:Log(string.format("[%s] batches x%s: changed %d, already %d, missing %d, failed %d",
        Reason, tostring(BATCH_MULTIPLIER), Changed, AlreadyDone, Missing, Failed))
    return true
end

-- ============================================
-- 8. More fragments
-- ============================================

local function IsFragmentRow(Name, Row)
    local ok, IsFragment = pcall(function()
        return Row.Type == UE.EApprenticeshipRewardType.MartialFragment
    end)
    if ok and IsFragment then
        return true
    end
    return FRAGMENT_ROWS[Name] == true
end

function Mod:ApplyFragments(Reason)
    local DT = self:GetConfigTable(UE.EGameConfigType.ApprenticeshipReward)
    if not DT then
        return false
    end

    local RowNames = UE.UDataTableFunctionLibrary.GetDataTableRowNames(DT)
    local Changed, AlreadyDone, Failed = 0, 0, 0

    for i = 1, RowNames:Num() do
        local RowName = RowNames[i]
        local Name = UE.UKismetStringLibrary.Conv_NameToString(RowName)
        local Row = UE.FApprenticeshipReward()
        if UE.UDataTableFunctionLibrary.GetDataTableRowFromName(DT, RowName, Row) and IsFragmentRow(Name, Row) then
            if not OriginalFragments[Name] then
                OriginalFragments[Name] = { Min = Row.MinValue, Max = Row.MaxValue }
            end
            local Orig = OriginalFragments[Name]
            local WantMin = Round(Orig.Min * FRAGMENT_MULTIPLIER)
            local WantMax = Round(Orig.Max * FRAGMENT_MULTIPLIER)
            if Row.MinValue == WantMin and Row.MaxValue == WantMax then
                AlreadyDone = AlreadyDone + 1
            else
                Row.MinValue = WantMin
                Row.MaxValue = WantMax
                if UE.UModLuaLibrary.ReplaceDataTableRow(DT, RowName, Row) then
                    Changed = Changed + 1
                    self:Log(string.format("%s: %d-%d -> %d-%d", Name, Orig.Min, Orig.Max, WantMin, WantMax))
                else
                    Failed = Failed + 1
                end
            end
        end
    end

    self:Log(string.format("[%s] fragments x%s: changed %d, already %d, failed %d",
        Reason, tostring(FRAGMENT_MULTIPLIER), Changed, AlreadyDone, Failed))
    return true
end

-- ============================================
-- Table edits: apply all, retry until the tables exist
-- ============================================

-- Returns true once every table was found and processed.
function Mod:ApplyTables(Reason)
    local Done = true
    for _, Part in ipairs({ "ApplyBuildings", "ApplyBatches", "ApplyFragments" }) do
        local ok, result = pcall(function() return self[Part](self, Reason) end)
        if not ok then
            self:Log(Part .. " error: " .. tostring(result))
            Done = false
        elseif not result then
            Done = false
        end
    end
    return Done
end

function Mod:StartRetryTimer()
    self:StopRetryTimer()
    local Tries = 0
    self._RetryId = UE.UModLuaLibrary.RegisterModRepeatingTimer(nil, RETRY_INTERVAL, true, function()
        Tries = Tries + 1
        if self:ApplyTables("retry") or Tries >= MAX_RETRIES then
            self:StopRetryTimer()
        end
    end)
end

function Mod:StopRetryTimer()
    if self._RetryId then
        pcall(function() UE.UModLuaLibrary.UnregisterModRepeatingTimer(self._RetryId) end)
        self._RetryId = nil
    end
end

function Mod:RegisterEvents()
    self._EventIds = {}
    for _, EventName in ipairs({ "OnNewGameStarted", "OnLoadGameComplete" }) do
        pcall(function()
            local Id = UE.UModEventBus.RegisterModEvent(EventName, function()
                if not self:ApplyTables(EventName) then
                    self:StartRetryTimer()
                end
            end)
            table.insert(self._EventIds, Id)
        end)
    end
end

-- ============================================
-- 2, 3, 4. Hotkeys, demolish first, hide names
-- ============================================

function Mod:LoadClass(Path)
    self._Classes = self._Classes or {}
    if not self._Classes[Path] then
        pcall(function() self._Classes[Path] = UE.UClass.Load(Path) end)
    end
    return self._Classes[Path]
end

function Mod:GetWidgets(ClassPath)
    local World = self:GetWorld()
    local Class = self:LoadClass(ClassPath)
    if not World or not Class then
        return nil
    end
    local Widgets = UE.TArray(UE.UUserWidget)
    UE.UWidgetBlueprintLibrary.GetAllWidgetsOfClass(World, Widgets, Class, false)
    return Widgets
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

function Mod:IsKeyDown(PC, KeyName)
    if KeyName == nil or KeyName == "" then
        return false
    end
    self._Keys = self._Keys or {}
    if not self._Keys[KeyName] then
        self._Keys[KeyName] = MakeKey(KeyName)
    end
    local ok, Down = pcall(function() return PC:IsInputKeyDown(self._Keys[KeyName]) end)
    return ok and Down == true
end

-- True once per press (on the frame the key goes down).
function Mod:WasKeyJustPressed(PC, KeyName)
    local Down = self:IsKeyDown(PC, KeyName)
    self._KeyDown = self._KeyDown or {}
    local Was = self._KeyDown[KeyName] == true
    self._KeyDown[KeyName] = Down
    return Down and not Was
end

-- A widget counts as shown only if it and every parent up to its owning screen are visible.
local function IsShown(Widget)
    local Current = Widget
    for _ = 1, 40 do
        if not Current then
            return true
        end
        local ok, Visible = pcall(function() return Current:IsVisible() end)
        if not ok or not Visible then
            return false
        end
        local Parent = nil
        pcall(function() Parent = Current:GetParent() end)
        if not Parent then
            -- Top of this widget's tree: step out to the user widget that owns it.
            pcall(function()
                local Tree = UE.UKismetSystemLibrary.GetOuterObject(Current)
                local Owner = Tree and UE.UKismetSystemLibrary.GetOuterObject(Tree)
                if Owner and Owner.IsVisible then
                    Parent = Owner
                end
            end)
        end
        Current = Parent
    end
    return true
end

local function ButtonID(Button)
    local ID = nil
    pcall(function()
        ID = UE.UKismetStringLibrary.Conv_NameToString(Button.CommonButtonInfo.ID)
    end)
    return ID
end

local function IsEnabled(Button)
    local ok, Enabled = pcall(function() return Button:GetIsEnabled() end)
    return not ok or Enabled ~= false
end

local function IsSelected(Button)
    local ok, Selected = pcall(function() return Button:GetSelected() end)
    return ok and Selected == true
end

-- Returns { [ID] = button } for every order button currently on screen.
function Mod:GetShownButtons()
    local Found = {}
    local Buttons = self:GetWidgets(BUTTON_CLASS_PATH)
    if not Buttons then
        return Found
    end
    for i = 1, Buttons:Length() do
        local Button = Buttons:Get(i)
        if Button then
            local ID = ButtonID(Button)
            if ID and not Found[ID] and IsShown(Button) then
                Found[ID] = Button
            end
        end
    end
    return Found
end

-- Clicks a button the same way the mouse does. Falls back to the game's own
-- functions if the click handler can't be called.
function Mod:ClickButton(Button, ID)
    local ok, err = pcall(function() Button:HandleButtonClicked() end)
    if ok then
        return true
    end
    self:LogOnce("click_" .. ID, "HandleButtonClicked failed for " .. ID .. ": " .. tostring(err))
    local Fallback = nil
    if ID == "PriorityExecution" then
        Fallback = function() Button:ImmediatelyExecute() end
    elseif ID == "CancelOrder" then
        Fallback = function() Button:NativeCancelAllSelectObjectOrder() end
    else
        Fallback = function() Button:NativeFellAndHarvest() end
    end
    ok, err = pcall(Fallback)
    if not ok then
        self:LogOnce("fallback_" .. ID, "Fallback failed for " .. ID .. ": " .. tostring(err))
    end
    return ok
end

-- Clicks the first shown, enabled button from the list.
function Mod:PressFirst(List, What)
    local Shown = self:GetShownButtons()
    for _, ID in ipairs(List) do
        local Button = Shown[ID]
        if Button and IsEnabled(Button) then
            self:ClickButton(Button, ID)
            return true
        end
    end
    self:LogOnce("none_" .. What, "Hotkey " .. What .. ": no matching button on screen (select something first)")
    return false
end

function Mod:CheckHotkeys()
    local PC = self:GetPlayerController()
    if not PC then
        return
    end
    -- Leave Ctrl/Alt combinations to the game.
    if self:IsKeyDown(PC, "LeftControl") or self:IsKeyDown(PC, "LeftAlt") then
        return
    end
    if self:WasKeyJustPressed(PC, KEY_CUT) then
        self:PressFirst(CUT_BUTTONS, "cut")
    end
    if self:WasKeyJustPressed(PC, KEY_HARVEST) then
        self:PressFirst(HARVEST_BUTTONS, "harvest")
    end
    if self:WasKeyJustPressed(PC, KEY_CANCEL) then
        self:PressFirst(CANCEL_BUTTONS, "cancel")
    end
    if self:WasKeyJustPressed(PC, KEY_PRIORITY) then
        self:PressFirst(PRIORITY_BUTTONS, "priority")
    end
    if self:WasKeyJustPressed(PC, KEY_TOGGLE_NAMES) then
        self._HideNames = not self._HideNames
        self:Log("Names " .. (self._HideNames and "hidden" or "shown"))
        self:ApplyNames()
    end
end

-- When the selection panel shows an active Deconstruct order and Priority Execution
-- is off, switch it on. Each priority button is only clicked once, so the player can
-- still switch it off again by hand.
function Mod:ApplyDemolishFirst()
    if not DEMOLISH_FIRST then
        return
    end
    local Shown = self:GetShownButtons()
    local Demolishing = false
    for ID, Button in pairs(Shown) do
        if DEMOLISH_BUTTONS[ID] and IsSelected(Button) then
            Demolishing = true
            break
        end
    end
    local Priority = Shown["PriorityExecution"]
    if not Demolishing or not Priority or IsSelected(Priority) or not IsEnabled(Priority) then
        return
    end
    self._PriorityClicked = self._PriorityClicked or setmetatable({}, { __mode = "k" })
    if self._PriorityClicked[Priority] then
        return
    end
    self._PriorityClicked[Priority] = true
    if self:ClickButton(Priority, "PriorityExecution") then
        self:LogOnce("demolish_ok", "Demolish first: gave a deconstruct order priority")
    end
end

function Mod:SetLabelHidden(Label, Hidden)
    if not Label then
        return
    end
    self._OriginalVis = self._OriginalVis or setmetatable({}, { __mode = "k" })
    if Hidden then
        local Current = Label:GetVisibility()
        if Current ~= UE.ESlateVisibility.Collapsed then
            self._OriginalVis[Label] = Current
            Label:SetVisibility(UE.ESlateVisibility.Collapsed)
        end
    elseif self._OriginalVis[Label] ~= nil then
        Label:SetVisibility(self._OriginalVis[Label])
        self._OriginalVis[Label] = nil
    end
end

function Mod:ApplyNames()
    local Bars = self:GetWidgets(STATEBAR_CLASS_PATH)
    if not Bars then
        return
    end
    for i = 1, Bars:Length() do
        local Bar = Bars:Get(i)
        if Bar then
            local ok, err = pcall(function()
                self:SetLabelHidden(Bar.TextBlock_Name, self._HideNames)
                self:SetLabelHidden(Bar.RichTextBlock_Suffix, self._HideNames and HIDE_TITLES)
            end)
            if not ok then
                self:LogOnce("names_err", "Name hiding error: " .. tostring(err))
            end
        end
    end
end

function Mod:StartTimer(Interval, Tag, Fn)
    return UE.UModLuaLibrary.RegisterModRepeatingTimer(nil, Interval, true, function()
        local ok, err = pcall(Fn)
        if not ok then
            self:LogOnce("timer_" .. Tag, Tag .. " error: " .. tostring(err))
        end
    end)
end

-- ============================================
-- Lifecycle
-- ============================================

function Mod:OnModLoaded()
    self._HideNames = HIDE_NAMES
    self:Log(string.format("QoL loaded (cut %s, harvest %s, cancel %s, priority %s, names %s)",
        KEY_CUT, KEY_HARVEST, KEY_CANCEL, KEY_PRIORITY, KEY_TOGGLE_NAMES))

    if not self:ApplyTables("load") then
        self:StartRetryTimer()
    end
    self:RegisterEvents()

    self._Timers = {
        self:StartTimer(KEY_INTERVAL, "Hotkeys", function() self:CheckHotkeys() end),
        self:StartTimer(SLOW_INTERVAL, "Background", function()
            self:ApplyDemolishFirst()
            if self._HideNames or next(self._OriginalVis or {}) then
                self:ApplyNames()
            end
        end),
    }
end

function Mod:OnModUnloaded()
    self:StopRetryTimer()
    for _, Id in ipairs(self._EventIds or {}) do
        pcall(function() UE.UModEventBus.UnregisterModEvent(Id) end)
    end
    for _, Id in ipairs(self._Timers or {}) do
        pcall(function() UE.UModLuaLibrary.UnregisterModRepeatingTimer(Id) end)
    end
    self._Timers = nil
end

return Mod
