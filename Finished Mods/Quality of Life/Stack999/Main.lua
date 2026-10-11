-- ============================================
-- Stack999: every stackable item stacks to 999.
-- Edits MaxStackSize and SmallGridCount (storage spaces per stack) in DT_InventoryItem,
-- in memory only (never touches the save).
-- Everything else about items (weight, hauling, spoiling) stays vanilla.
-- Items with MaxStackSize 1 (recipes, puppet cores, unique items) are left alone;
-- equipment/weapons/books live in other tables and are always 1.
-- Safe to run repeatedly: rows already at STACK_SIZE are skipped.
-- ============================================

local Mod = {}

-- ===== Config =====
local STACK_SIZE = 999
-- Only rows whose vanilla MaxStackSize is at least this are raised (1 = not stackable).
local MIN_VANILLA_STACK = 2
-- Storage spaces one stack takes up. Bulky items (logs, ore, stone, cloth, feed) use 4 in vanilla,
-- so a 4-space depot only fits one stack. 1 = every stack uses one space. Set to 0 to keep vanilla sizes.
local SPACES_PER_STACK = 1
-- Item IDs to never change, e.g. { "10601" }.
local EXCLUDE_IDS = {}
-- How often to retry until the game's config table is available (seconds).
local RETRY_INTERVAL = 1.0
local MAX_RETRIES = 120

-- ============================================
-- Helpers
-- ============================================

function Mod:Log(Message)
    -- Only "error" level reliably reaches the game log.
    UE.UModLuaLibrary.ModLog(self.ModInfo.Metadata.ModId, Message, "error")
end

function Mod:GetWorld()
    local GI = UE.UGameplayStatics.GetGameInstance(self.ModInfo)
    if not GI then
        return nil
    end
    return GI:GetWorld()
end

function Mod:GetInventoryTable()
    local World = self:GetWorld()
    if not World then
        return nil
    end
    local GameMode = UE.UGameplayStatics.GetGameMode(World)
    if not GameMode or not GameMode.GameConfigComponent then
        return nil
    end
    local DT = GameMode.GameConfigComponent:GetGameConfigByType(UE.EGameConfigType.InventoryItem)
    if not DT or not DT:IsValid() then
        return nil
    end
    return DT
end

-- ============================================
-- Core
-- ============================================

-- Returns true once the table was found and processed.
function Mod:ApplyStackSize(Reason)
    local DT = self:GetInventoryTable()
    if not DT then
        return false
    end

    local Excluded = {}
    for _, ID in ipairs(EXCLUDE_IDS) do
        Excluded[ID] = true
    end

    local RowNames = UE.UDataTableFunctionLibrary.GetDataTableRowNames(DT)
    local Changed, AlreadyDone, Skipped, Failed = 0, 0, 0, 0

    for i = 1, RowNames:Num() do
        local RowName = RowNames[i]
        local Row = UE.FInventoryItem()
        if UE.UDataTableFunctionLibrary.GetDataTableRowFromName(DT, RowName, Row) then
            local OldStack = Row.MaxStackSize or 0
            local WantSpaces = SPACES_PER_STACK > 0 and SPACES_PER_STACK or Row.SmallGridCount
            if OldStack < MIN_VANILLA_STACK or Excluded[UE.UKismetStringLibrary.Conv_NameToString(RowName)] then
                Skipped = Skipped + 1
            elseif OldStack == STACK_SIZE and Row.SmallGridCount == WantSpaces then
                AlreadyDone = AlreadyDone + 1
            else
                Row.MaxStackSize = STACK_SIZE
                Row.SmallGridCount = WantSpaces
                if UE.UModLuaLibrary.ReplaceDataTableRow(DT, RowName, Row) then
                    Changed = Changed + 1
                else
                    Failed = Failed + 1
                end
            end
        end
    end

    self:Log(string.format("[%s] MaxStackSize -> %d, spaces -> %d: changed %d, already %d, skipped %d, failed %d",
        Reason, STACK_SIZE, SPACES_PER_STACK, Changed, AlreadyDone, Skipped, Failed))
    return true
end

function Mod:SafeApply(Reason)
    local ok, result = pcall(function() return self:ApplyStackSize(Reason) end)
    if not ok then
        self:Log("Apply error: " .. tostring(result))
        return false
    end
    return result
end

-- Retry on a timer until the GameMode/config table exists, then stop.
function Mod:StartRetryTimer()
    self:StopRetryTimer()
    local Tries = 0
    self._TimerId = UE.UModLuaLibrary.RegisterModRepeatingTimer(nil, RETRY_INTERVAL, true, function()
        Tries = Tries + 1
        if self:SafeApply("retry") or Tries >= MAX_RETRIES then
            self:StopRetryTimer()
        end
    end)
end

function Mod:StopRetryTimer()
    if self._TimerId then
        pcall(function() UE.UModLuaLibrary.UnregisterModRepeatingTimer(self._TimerId) end)
        self._TimerId = nil
    end
end

function Mod:RegisterEvents()
    self._EventIds = {}
    for _, EventName in ipairs({ "OnNewGameStarted", "OnLoadGameComplete" }) do
        pcall(function()
            local Id = UE.UModEventBus.RegisterModEvent(EventName, function()
                if not self:SafeApply(EventName) then
                    self:StartRetryTimer()
                end
            end)
            table.insert(self._EventIds, Id)
        end)
    end
end

-- ============================================
-- Lifecycle
-- ============================================

function Mod:OnModLoaded()
    self:Log("Stack999 loaded")
    if not self:SafeApply("load") then
        self:StartRetryTimer()
    end
    self:RegisterEvents()
end

function Mod:OnModUnloaded()
    self:StopRetryTimer()
    for _, Id in ipairs(self._EventIds or {}) do
        pcall(function() UE.UModEventBus.UnregisterModEvent(Id) end)
    end
end

return Mod
