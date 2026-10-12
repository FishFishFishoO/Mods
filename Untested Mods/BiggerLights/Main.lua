-- ============================================
-- BiggerLights: gives lamps a bigger light range so fewer of them can light a big room.
-- Scales BuildingEffectSize (the lit area) on every light source in DT_Buildconfig,
-- in memory only (never touches the save).
--
-- Vanilla light ranges (tiles added around the lamp):
--   3: oil lamp, bronze table lamp
--   4: palace/octagonal lanterns, wall lamps, torch, candlestick, floor lamp, spirit lamp
--   5: street lamps, moon lamp, brazier, bonfire
--   6: cloud-shadow moon lamp
-- Windows are light sources too but have no range, so they are left alone.
--
-- Performance: gameplay range only. The visible lights are left exactly as vanilla,
-- so the mod adds no lights, no shadows and no extra rendering cost. It runs once per
-- game load and does nothing while you play.
-- Safe to run repeatedly: always scales the original values, never stacks.
-- ============================================

local Mod = {}

-- ===== Config =====
-- 1 = vanilla, 1.5 = 50% bigger, 2 = twice the range.
local RANGE_MULT = 2
-- 1 = vanilla. Scales each lamp's Luminance (LightSourceTemperatureEffect).
local LIGHT_VALUE_MULT = 1
-- How often to retry until the game's config table is available (seconds).
local RETRY_INTERVAL = 1.0
local MAX_RETRIES = 120

-- Original values per row, recorded the first time each row is seen.
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

local function ScaledInt(Value, Mult)
    if Value <= 0 or Mult <= 0 then
        return Value
    end
    return math.max(1, math.floor(Value * Mult + 0.5))
end

-- ============================================
-- Core
-- ============================================

-- Returns true once the table was found and processed.
function Mod:ApplyLights(Reason)
    local DT = self:GetBuildTable()
    if not DT then
        return false
    end

    local RowNames = UE.UDataTableFunctionLibrary.GetDataTableRowNames(DT)
    local Changed, AlreadyDone, Failed = 0, 0, 0

    for i = 1, RowNames:Num() do
        local RowName = RowNames[i]
        local Name = UE.UKismetStringLibrary.Conv_NameToString(RowName)
        local Row = UE.FBuildConfigData()
        if UE.UDataTableFunctionLibrary.GetDataTableRowFromName(DT, RowName, Row)
            and Row.IsLightSource and Row.HaveEffectSize then
            if Original[Name] == nil then
                Original[Name] = {
                    SizeX = Row.BuildingEffectSize.X,
                    SizeY = Row.BuildingEffectSize.Y,
                    Value = Row.LightSourceTemperatureEffect,
                }
            end
            local Snap = Original[Name]
            local WantX = ScaledInt(Snap.SizeX, RANGE_MULT)
            local WantY = ScaledInt(Snap.SizeY, RANGE_MULT)
            local WantValue = ScaledInt(Snap.Value, LIGHT_VALUE_MULT)

            if Row.BuildingEffectSize.X == WantX and Row.BuildingEffectSize.Y == WantY
                and Row.LightSourceTemperatureEffect == WantValue then
                AlreadyDone = AlreadyDone + 1
            else
                local Size = Row.BuildingEffectSize
                Size.X = WantX
                Size.Y = WantY
                Row.BuildingEffectSize = Size
                Row.LightSourceTemperatureEffect = WantValue
                if UE.UModLuaLibrary.ReplaceDataTableRow(DT, RowName, Row) then
                    Changed = Changed + 1
                else
                    Failed = Failed + 1
                end
            end
        end
    end

    self:Log(string.format("[%s] range x%s, luminance x%s: changed %d, already %d, failed %d",
        Reason, tostring(RANGE_MULT), tostring(LIGHT_VALUE_MULT), Changed, AlreadyDone, Failed))
    return true
end

function Mod:SafeApply(Reason)
    local ok, result = pcall(function() return self:ApplyLights(Reason) end)
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
    self:Log("BiggerLights loaded")
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
