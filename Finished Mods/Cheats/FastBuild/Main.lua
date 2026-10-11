-- ============================================
-- Instant Build (ModId FastBuild): buildings finish as soon as the materials are delivered.
-- Divides Workload in DT_Buildconfig, in memory only (never touches the save).
-- Vanilla: most buildings need ~1500 work, the biggest 20000.
-- Demolish work (DestoryWorkload) is left alone.
-- Safe to run repeatedly: always divides the original values, never stacks.
-- ============================================

local Mod = {}

-- ===== Config =====
-- 2 = twice as fast, 4 = four times as fast.
-- 0 = instant: the builder still brings the materials, then it finishes straight away.
local BUILD_SPEED = 0
-- How often to retry until the game's config table is available (seconds).
local RETRY_INTERVAL = 1.0
local MAX_RETRIES = 120

-- Original Workload per row, recorded the first time each row is seen.
local Original = {}

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

function Mod:GetBuildTable()
    local World = self:GetWorld()
    if not World then
        return nil
    end
    local GameMode = UE.UGameplayStatics.GetGameMode(World)
    if not GameMode or not GameMode.GameConfigComponent then
        return nil
    end
    local DT = GameMode.GameConfigComponent:GetGameConfigByType(UE.EGameConfigType.BuildConfig)
    if not DT or not DT:IsValid() then
        return nil
    end
    return DT
end

function Mod:TargetWorkload(OriginalWorkload)
    if BUILD_SPEED <= 0 then
        return 1
    end
    return math.max(1, math.floor(OriginalWorkload / BUILD_SPEED + 0.5))
end

-- ============================================
-- Core
-- ============================================

-- Returns true once the table was found and processed.
function Mod:ApplyBuildSpeed(Reason)
    local DT = self:GetBuildTable()
    if not DT then
        return false
    end

    local RowNames = UE.UDataTableFunctionLibrary.GetDataTableRowNames(DT)
    local Changed, AlreadyDone, Skipped, Failed = 0, 0, 0, 0

    for i = 1, RowNames:Num() do
        local RowName = RowNames[i]
        local Name = UE.UKismetStringLibrary.Conv_NameToString(RowName)
        local Row = UE.FBuildConfigData()
        if UE.UDataTableFunctionLibrary.GetDataTableRowFromName(DT, RowName, Row) then
            if not Original[Name] then
                Original[Name] = Row.Workload
            end
            if Original[Name] <= 1 then
                -- Already instant in vanilla.
                Skipped = Skipped + 1
            else
                local Want = self:TargetWorkload(Original[Name])
                if Row.Workload == Want then
                    AlreadyDone = AlreadyDone + 1
                else
                    Row.Workload = Want
                    if UE.UModLuaLibrary.ReplaceDataTableRow(DT, RowName, Row) then
                        Changed = Changed + 1
                    else
                        Failed = Failed + 1
                    end
                end
            end
        end
    end

    self:Log(string.format("[%s] build speed %s: changed %d, already %d, skipped %d, failed %d",
        Reason, BUILD_SPEED <= 0 and "instant" or ("x" .. tostring(BUILD_SPEED)),
        Changed, AlreadyDone, Skipped, Failed))
    return true
end

function Mod:SafeApply(Reason)
    local ok, result = pcall(function() return self:ApplyBuildSpeed(Reason) end)
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
    self:Log("Instant Build loaded")
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
