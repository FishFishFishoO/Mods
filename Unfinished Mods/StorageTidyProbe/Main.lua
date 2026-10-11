-- ============================================
-- StorageTidyProbe: TEST mod for the future "Storage Tidy" mod.
-- Checks whether a script can switch a storage's "Keep empty" on/off and whether
-- disciples then haul from it like when you press the button yourself.
--
-- K = list every storage (priority, Keep empty state, stacks) in a popup + the log.
-- L = toggle "Keep empty" on the storage you have selected (click it first).
-- O = in the selected storage, untick its FIRST item in the restrictions and boost hauling there.
-- M = undo O (tick the item back on, remove the boost).
-- Nothing runs automatically; it only acts when you press a key.
-- ============================================

local Mod = {}

local LIST_KEY = "K"
local TOGGLE_KEY = "L"
local RESTRICT_KEY = "O"
local UNDO_KEY = "M"
local POLL_INTERVAL = 0.1

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

-- On-screen message (and the log), so results can be read without finding the log file.
function Mod:Notify(Message)
    self:Log(Message)
    pcall(function()
        local PC = self:GetPlayerController()
        if PC and PC.ShowNotifyMessage then
            PC:ShowNotifyMessage(UE.FText.FromString(Message))
        end
    end)
end

-- Same key lookup as the CombatStats mod (UE.EKeys), with FKey.KeyName as a fallback.
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
    local Down = false
    local Key = MakeKey(KeyName)
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

local function IsStorage(Actor)
    local ok, Result = pcall(function()
        local Inv = Actor.InventoryManagerComponent
        return Inv ~= nil and Inv.InventoryItemSetType == UE.EInventoryItemSetType.Warehouse
    end)
    return ok and Result
end

function Mod:GetKeepClear(Building)
    local Value = Building.ButtonOperationState:Find(UE.ECommonButtonType.KeepClear)
    return Value == true
end

function Mod:DescribeStorage(Building)
    local Name = "?"
    pcall(function() Name = tostring(Building:K2_GetBuildingName()) end)
    local Priority = Building.InventoryManagerComponent.StoragePriority
    local Items = Building.InventoryManagerComponent:GetAllInventoryItems()
    return string.format("%s | priority %d | keep empty %s | %d stacks",
        Name, Priority, tostring(self:GetKeepClear(Building)), Items:Length())
end

-- ============================================
-- Tests
-- ============================================

function Mod:ListStorages()
    local World = self:GetWorld()
    if not World then
        return
    end
    local Buildings = UE.TArray(UE.ABuildingActorBase)
    UE.UGameplayStatics.GetAllActorsOfClass(World, UE.ABuildingActorBase, Buildings)
    local Count = 0
    for i = 1, Buildings:Length() do
        local Building = Buildings:Get(i)
        if Building and IsStorage(Building) then
            Count = Count + 1
            self:Log("  " .. self:DescribeStorage(Building))
        end
    end
    self:Notify(string.format("Storage Tidy test: found %d storages (details in log)", Count))
end

function Mod:ToggleSelected()
    local System = UE.ASelectInventorySubstituteSystem.GetSelectInventorySubstituteSystem(self.ModInfo)
    local Selected = System and System:GetSelectObjects()
    if not Selected or Selected:Length() == 0 then
        self:Notify("Storage Tidy test: click a storage first, then press " .. TOGGLE_KEY)
        return
    end
    local Building = Selected:Get(1)
    if not IsStorage(Building) then
        self:Notify("Storage Tidy test: the selected object is not a storage")
        return
    end

    local Before = self:GetKeepClear(Building)
    Building.ButtonOperationState:Add(UE.ECommonButtonType.KeepClear, not Before)
    local After = self:GetKeepClear(Building)
    self:Notify(string.format("Storage Tidy test: keep empty %s -> %s | %s",
        tostring(Before), tostring(After), self:DescribeStorage(Building)))
end

-- ---------- O / M: per-item restriction + hauling boost ----------

local HAUL_ACTIONS = { "TransItem", "Transport" }

-- Add hauling to the game's "boost priority" list (normally cooking, building, mining...).
function Mod:EnsureHaulingBoostable()
    if self._BoostListPatched then
        return
    end
    local World = self:GetWorld()
    local GameMode = UE.UGameplayStatics.GetGameMode(World)
    local Asset = GameMode.GameConfigComponent:GetGameDataAssetByType(UE.EGameDataAssetType.GamePlayConfiguration)
    local List = Asset.CanImprovePriorityActions
    for _, ActionID in ipairs(HAUL_ACTIONS) do
        local Found = false
        for i = 1, List:Length() do
            if tostring(List:Get(i)) == ActionID then
                Found = true
            end
        end
        if not Found then
            List:Add(ActionID)
        end
    end
    self._BoostListPatched = true
end

function Mod:GetSelectedStorage()
    local System = UE.ASelectInventorySubstituteSystem.GetSelectInventorySubstituteSystem(self.ModInfo)
    local Selected = System and System:GetSelectObjects()
    if not Selected or Selected:Length() == 0 then
        self:Notify("Storage Tidy test: click a storage first")
        return nil
    end
    local Building = Selected:Get(1)
    if not IsStorage(Building) then
        self:Notify("Storage Tidy test: the selected object is not a storage")
        return nil
    end
    return Building
end

-- Untick the FIRST item in the selected storage's restrictions and boost its hauling.
function Mod:TestRestrictFirstItem()
    local Building = self:GetSelectedStorage()
    if not Building then
        return
    end
    local Inv = Building.InventoryManagerComponent
    local Items = Inv:GetAllInventoryItems()
    if Items:Length() == 0 then
        self:Notify("Storage Tidy test: that storage is empty, pick one with items")
        return
    end

    local Data = Items:Get(1):GetInventoryGeneralData()
    local Tag = Data.GameplayTag
    local Tags = Inv.NotPutInItemTagContainer
    UE.UBlueprintGameplayTagLibrary.AddGameplayTag(Tags, Tag)
    Inv.NotPutInItemTagContainer = Tags

    self:EnsureHaulingBoostable()
    Building.GOAP_ActionComponent:ImproveActionPriority()

    self._TestBuilding = Building
    self._TestTag = Tag
    self:Notify(string.format("Storage Tidy test: blocked %s here and boosted hauling. Watch if disciples carry it out.",
        tostring(Tag.TagName)))
end

-- Undo O: re-allow the item and remove the boost.
function Mod:TestUndoRestrict()
    local Building = self._TestBuilding
    if not Building or not self._TestTag then
        self:Notify("Storage Tidy test: nothing to undo")
        return
    end
    local Inv = Building.InventoryManagerComponent
    local Tags = Inv.NotPutInItemTagContainer
    UE.UBlueprintGameplayTagLibrary.RemoveGameplayTag(Tags, self._TestTag)
    Inv.NotPutInItemTagContainer = Tags
    Building.GOAP_ActionComponent:CancelImproveActionPriority()
    self:Notify("Storage Tidy test: allowed " .. tostring(self._TestTag.TagName) .. " again, boost removed")
    self._TestBuilding = nil
    self._TestTag = nil
end

-- ============================================
-- Lifecycle
-- ============================================

function Mod:OnModLoaded()
    self:Log("StorageTidyProbe loaded (v0.1.2, keys K/L/O/M)")
    self._TimerId = UE.UModLuaLibrary.RegisterModRepeatingTimer(nil, POLL_INTERVAL, true, function()
        local Keys = {
            [LIST_KEY] = self.ListStorages,
            [TOGGLE_KEY] = self.ToggleSelected,
            [RESTRICT_KEY] = self.TestRestrictFirstItem,
            [UNDO_KEY] = self.TestUndoRestrict,
        }
        for KeyName, Action in pairs(Keys) do
            if self:WasKeyJustPressed(KeyName) then
                local ok, err = pcall(Action, self)
                if not ok then
                    self:Notify("Storage Tidy test error: " .. tostring(err))
                end
            end
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
