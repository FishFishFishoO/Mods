-- ============================================
-- FreshFirstProbe: TEST mod for a future "Fresh First" mod (haul food before it spoils).
-- Disciples pick the cheapest job first. Every item lying around has a haul job
-- ("Transport" / "TransItem") with a Cost. This test lowers that Cost for items that
-- spoil quickly (food), the same way the game's own "prioritize" lowers a job's cost.
--
-- v0.1.x read WarehouseManagerSubsystem's haul cache, but it was always empty.
-- v0.2.0 reads the real job list instead: WorldPlace.GOAP_ManagerComponent.ItemActions
--   ItemActions  Map<GoalID, FItemActions>
--     .Actions   Map<ItemID, FActionData>
--       .OwnerData Map<UObjectData(the item), FGOAP_Actions>
--         .Actions Map<FGOAP_Action(has .Cost), bool(active)>
--
-- G  = report: write the job list (goals, haul jobs per item, cost, shelf life) to the
--      mod log and show a short popup.
-- F9 = turn "food first" on/off. While on, every second, haul jobs for quick-spoiling
--      items get Cost = original - REDUCE_COST. Turning it off puts the original costs back.
-- Nothing is saved; it only changes the in-memory job list.
-- ============================================

local Mod = {}

-- ===== Config =====
local REPORT_KEY = "G"
local TOGGLE_KEY = "F9"
-- Items that spoil within this many game days (outdoors) count as "fresh" (food).
-- Vanilla: food 1-15 days, flour/feed 30, dried food 40, materials 80+.
local FRESH_DAYS = 20
-- Haul job IDs (DT_GoapActionData): TransItem cost 50 "Transporting", Transport cost 100 "Stocking".
local HAUL_ACTIONS = { TransItem = true, Transport = true }
-- How much cheaper fresh haul jobs become. The game's own "prioritize" uses 500
-- (DA_GamePlayConfigurationAsset.ActionReduceCostValue).
local REDUCE_COST = 500
local POLL_INTERVAL = 0.1
local BOOST_INTERVAL = 1.0
local SECONDS_PER_DAY = 960
local MAX_REPORT_LINES = 40

-- ============================================
-- Helpers
-- ============================================

function Mod:Log(Message)
    UE.UModLuaLibrary.ModLog(self.ModInfo.Metadata.ModId, Message, "error")
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

function Mod:Notify(Message)
    self:Log(Message)
    local ok, err = pcall(function()
        local PC = self:GetPlayerController()
        PC:ShowNotifyMessage(UE.FText.FromString(Message))
    end)
    if not ok and not self._NotifyErrorLogged then
        self._NotifyErrorLogged = true
        self:Log("Popup error: " .. tostring(err))
    end
end

-- Same key lookup as the Storage Tidy test (UE.EKeys), with FKey.KeyName as a fallback.
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

function Mod:WasKeyJustPressed(KeyName)
    local PC = self:GetPlayerController()
    local Key = MakeKey(KeyName)
    local Down = false
    if PC and Key then
        local ok, err = pcall(function()
            Down = PC:IsInputKeyDown(Key) == true
        end)
        if not ok and not self._KeyErrorLogged then
            self._KeyErrorLogged = true
            self:Log("Key check error: " .. tostring(err))
        end
    elseif not self._KeySetupLogged then
        self._KeySetupLogged = true
        self:Log(string.format("Key check not ready: controller %s, key %s", tostring(PC ~= nil), tostring(Key ~= nil)))
    end
    self._KeyDown = self._KeyDown or {}
    local Was = self._KeyDown[KeyName] == true
    self._KeyDown[KeyName] = Down
    return Down and not Was
end

-- Shelf life in game days for an item ID, or nil if it never spoils / is unknown. Cached.
function Mod:GetShelfDays(ItemID)
    self._ShelfDays = self._ShelfDays or {}
    local Key = tostring(ItemID)
    if self._ShelfDays[Key] ~= nil then
        return self._ShelfDays[Key] or nil
    end
    local Days = false
    pcall(function()
        local World = self:GetWorld()
        local GameMode = UE.UGameplayStatics.GetGameMode(World)
        local DT = GameMode.GameConfigComponent:GetGameConfigByType(UE.EGameConfigType.InventoryItem)
        local Row = UE.FInventoryItem()
        if UE.UDataTableFunctionLibrary.GetDataTableRowFromName(DT, ItemID, Row) and Row.ItemShelfLife > 0 then
            Days = Row.ItemShelfLife / SECONDS_PER_DAY
        end
    end)
    self._ShelfDays[Key] = Days
    return Days or nil
end

function Mod:IsFresh(ItemID)
    local Days = self:GetShelfDays(ItemID)
    return Days ~= nil and Days <= FRESH_DAYS
end

-- A stable text key for one job: owner guid + action ID.
local function JobKey(Owner, Action)
    local GuidText = "?"
    pcall(function()
        GuidText = UE.UKismetGuidLibrary.Conv_GuidToString(Owner.Guid)
    end)
    return GuidText .. "|" .. tostring(Action.ActionID)
end

-- The job list of the WorldPlace the player is in: the WorldPlace with the most item jobs.
function Mod:GetGOAPManager()
    local World = self:GetWorld()
    if not World then
        return nil, "no world"
    end
    local Best, BestCount, PlaceCount = nil, -1, 0
    local ok, err = pcall(function()
        local Places = UE.TArray(UE.AWorldPlace)
        UE.UGameplayStatics.GetAllActorsOfClass(World, UE.AWorldPlace, Places)
        PlaceCount = Places:Length()
        if not self._PlacesLogged then
            self._PlacesLogged = true
            self:Log(string.format("  found %d WorldPlaces", PlaceCount))
        end
        for i = 1, Places:Length() do
            local Place = Places:Get(i)
            local Manager = Place and Place.GOAP_ManagerComponent
            if Manager then
                local Count = Manager.ItemActions:Length()
                if Count > BestCount then
                    Best, BestCount = Manager, Count
                end
            end
        end
    end)
    if not ok then
        self:Log("  WorldPlace search error: " .. tostring(err))
    end
    if Best then
        if not self._ManagerLogged then
            self._ManagerLogged = true
            self:Log(string.format("  using job list with %d goals", BestCount))
        end
        return Best
    end
    return nil, string.format("no job list found (WorldPlaces: %d, error: %s)", PlaceCount, tostring(err))
end

-- Calls Visit(GoalID, ItemID, Owner, Action) for every job in ItemActions.
-- If Visit returns a changed Action, it replaces the old one (same active flag) and the
-- change is written back up through every map level. Returns jobs seen, jobs changed.
function Mod:ForEachItemJob(Visit)
    local Manager, Err = self:GetGOAPManager()
    if not Manager then
        return nil, Err
    end
    local Seen, Changed = 0, 0
    local Goals = Manager.ItemActions
    local GoalIDs = Goals:Keys()
    for g = 1, GoalIDs:Length() do
        local GoalID = GoalIDs:Get(g)
        local ItemActions = Goals:Find(GoalID)
        if ItemActions then
            local GoalChanged = false
            local ByItem = ItemActions.Actions
            local ItemIDs = ByItem:Keys()
            for i = 1, ItemIDs:Length() do
                local ItemID = ItemIDs:Get(i)
                local ActionData = ByItem:Find(ItemID)
                if ActionData then
                    local ItemChanged = false
                    local ByOwner = ActionData.OwnerData
                    local Owners = ByOwner:Keys()
                    for o = 1, Owners:Length() do
                        local Owner = Owners:Get(o)
                        local GOAPActions = ByOwner:Find(Owner)
                        if GOAPActions then
                            local OwnerChanged = false
                            local ActionMap = GOAPActions.Actions
                            local Actions = ActionMap:Keys()
                            for a = 1, Actions:Length() do
                                local Action = Actions:Get(a)
                                Seen = Seen + 1
                                local NewAction = Visit(GoalID, ItemID, Owner, Action)
                                if NewAction then
                                    local Active = ActionMap:Find(Action)
                                    ActionMap:Remove(Action)
                                    ActionMap:Add(NewAction, Active ~= false)
                                    Changed = Changed + 1
                                    OwnerChanged = true
                                end
                            end
                            if OwnerChanged then
                                ByOwner:Add(Owner, GOAPActions)
                                ItemChanged = true
                            end
                        end
                    end
                    if ItemChanged then
                        ByItem:Add(ItemID, ActionData)
                        GoalChanged = true
                    end
                end
            end
            if GoalChanged then
                Goals:Add(GoalID, ItemActions)
            end
        end
    end
    return Seen, Changed
end

-- ============================================
-- Report (G)
-- ============================================

-- Old v0.1 check, kept short: how big is the warehouse haul cache?
function Mod:ReportWarehouseCache()
    local ok, err = pcall(function()
        local World = self:GetWorld()
        local Subsystem = UE.USubsystemBlueprintLibrary.GetWorldSubsystem(World, UE.UWarehouseManagerSubsystem)
        if not Subsystem then
            self:Log("warehouse cache: subsystem not found")
            return
        end
        local Registered = Subsystem:GetRegisteredWarehouses()
        local CacheItems = 0
        for i = 1, Registered:Length() do
            local State = Subsystem:GetWarehouseState(Registered:Get(i))
            if State and State.TransportToWarehouseCache then
                CacheItems = CacheItems + State.TransportToWarehouseCache:Length()
            end
        end
        self:Log(string.format("warehouse cache: %d registered storages, %d states, %d cached item types",
            Registered:Length(), Subsystem.WarehouseStates:Length(), CacheItems))
    end)
    if not ok then
        self:Log("warehouse cache check error: " .. tostring(err))
    end
end

function Mod:Report()
    self:Log("step 1: G pressed, checking warehouse cache")
    self:ReportWarehouseCache()
    self:Log("step 2: reading job list")

    local GoalCounts, GoalOrder = {}, {}
    local Hauls, HaulOrder = {}, {}
    local Samples = 0
    local Seen, Err = self:ForEachItemJob(function(GoalID, ItemID, Owner, Action)
        local Goal = tostring(GoalID)
        if not GoalCounts[Goal] then
            GoalCounts[Goal] = 0
            table.insert(GoalOrder, Goal)
        end
        GoalCounts[Goal] = GoalCounts[Goal] + 1

        local ActionID = tostring(Action.ActionID)
        if HAUL_ACTIONS[ActionID] then
            local Key = tostring(ItemID) .. " " .. ActionID
            local H = Hauls[Key]
            if not H then
                H = { Count = 0, MinCost = math.huge, MaxCost = -math.huge, ItemID = ItemID }
                Hauls[Key] = H
                table.insert(HaulOrder, Key)
            end
            H.Count = H.Count + 1
            H.MinCost = math.min(H.MinCost, Action.Cost)
            H.MaxCost = math.max(H.MaxCost, Action.Cost)
        end
        if Samples < 3 then
            Samples = Samples + 1
            self:Log(string.format("  sample job: goal %s, action %s, item %s, cost %.1f, owner type %s",
                Goal, ActionID, tostring(Action.ItemId), Action.Cost, tostring(Owner.OwnerType)))
        end
        return nil
    end)
    if not Seen then
        self:Notify("Fresh First test: " .. tostring(Err))
        return
    end
    self:Log("step 3: job list read")

    local GoalText = {}
    for _, Goal in ipairs(GoalOrder) do
        table.insert(GoalText, string.format("%s x%d", Goal, GoalCounts[Goal]))
    end
    self:Log(string.format("---- job list: %d item jobs, food first %s ----", Seen, self._BoostOn and "ON" or "off"))
    self:Log("  goals: " .. (#GoalText > 0 and table.concat(GoalText, ", ") or "(none)"))

    local FreshCount, HaulCount = 0, 0
    for n, Key in ipairs(HaulOrder) do
        local H = Hauls[Key]
        local Days = self:GetShelfDays(H.ItemID)
        local Fresh = Days ~= nil and Days <= FRESH_DAYS
        HaulCount = HaulCount + H.Count
        if Fresh then
            FreshCount = FreshCount + H.Count
        end
        if n <= MAX_REPORT_LINES then
            self:Log(string.format("  haul %s x%d | cost %.1f to %.1f | spoils %s | %s",
                Key, H.Count, H.MinCost, H.MaxCost,
                Days and string.format("%.1f days", Days) or "never",
                Fresh and "FRESH" or "-"))
        end
    end
    self:Notify(string.format("Fresh First test: %d haul jobs, %d fresh, food first %s (details in log)",
        HaulCount, FreshCount, self._BoostOn and "ON" or "off"))
end

-- ============================================
-- Food first (F9)
-- ============================================

function Mod:ApplyBoost()
    self._Original = self._Original or {}
    local Seen, Changed = self:ForEachItemJob(function(GoalID, ItemID, Owner, Action)
        if not HAUL_ACTIONS[tostring(Action.ActionID)] or not self:IsFresh(ItemID) then
            return nil
        end
        local Key = JobKey(Owner, Action)
        if self._Original[Key] == nil then
            self._Original[Key] = Action.Cost
        end
        local Target = self._Original[Key] - REDUCE_COST
        if Action.Cost <= Target then
            return nil
        end
        Action.Cost = Target
        return Action
    end)
    if Seen and Changed > 0 then
        self._BoostWrites = (self._BoostWrites or 0) + Changed
        if self._BoostWrites == Changed then
            self:Log(string.format("Boost lowered %d fresh haul jobs (of %d jobs)", Changed, Seen))
        elseif not self._LoggedRewrite then
            -- A later pass had to lower jobs again: either new food appeared, or the game reset our costs.
            self._LoggedRewrite = true
            self:Log(string.format("Boost had to lower %d jobs again (new food, or the game reset them)", Changed))
        end
    end
    return Seen, Changed
end

function Mod:RemoveBoost()
    if not self._Original then
        return 0
    end
    local Seen, Changed = self:ForEachItemJob(function(GoalID, ItemID, Owner, Action)
        local Original = self._Original[JobKey(Owner, Action)]
        if Original == nil or Action.Cost == Original then
            return nil
        end
        Action.Cost = Original
        return Action
    end)
    self._Original = nil
    if not Seen then
        return 0
    end
    return Changed
end

function Mod:ToggleBoost()
    self:Log("F9 pressed")
    self._BoostOn = not self._BoostOn
    if self._BoostOn then
        self._BoostWrites = 0
        self._LoggedRewrite = false
        local Seen, Changed = self:ApplyBoost()
        if not Seen then
            self:Notify("Fresh First test: food first ON, but " .. tostring(Changed))
            return
        end
        self:Notify(string.format("Fresh First test: food first ON (%d fresh haul jobs made cheaper)", Changed))
    else
        local Restored = self:RemoveBoost()
        self:Notify(string.format("Fresh First test: food first off (%d jobs put back)", Restored))
    end
end

-- ============================================
-- Lifecycle
-- ============================================

function Mod:OnModLoaded()
    self:Log("FreshFirstProbe loaded (v0.2.1, keys G/F9)")
    local SinceBoost = 0
    self._TimerId = UE.UModLuaLibrary.RegisterModRepeatingTimer(nil, POLL_INTERVAL, true, function()
        if not self._TickLogged then
            self._TickLogged = true
            self:Log("timer running")
        end
        local ok, err = pcall(function()
            if self:WasKeyJustPressed(REPORT_KEY) then
                self:Report()
            end
            if self:WasKeyJustPressed(TOGGLE_KEY) then
                self:ToggleBoost()
            end
            if self._BoostOn then
                SinceBoost = SinceBoost + POLL_INTERVAL
                if SinceBoost >= BOOST_INTERVAL then
                    SinceBoost = 0
                    self:ApplyBoost()
                end
            end
        end)
        if not ok and not self._ErrorLogged then
            self._ErrorLogged = true
            self:Notify("Fresh First test error: " .. tostring(err))
        end
    end)
end

function Mod:OnModUnloaded()
    if self._TimerId then
        pcall(function() UE.UModLuaLibrary.UnregisterModRepeatingTimer(self._TimerId) end)
        self._TimerId = nil
    end
end

return Mod
