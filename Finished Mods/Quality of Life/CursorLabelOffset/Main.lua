-- ============================================
-- CursorLabelOffset: makes the label that follows the mouse (size like "4x8", tips,
-- resource costs) float above the cursor instead of sitting under it.
-- The cursor itself is not changed.
-- The game pins W_FollowMouse's top-left corner to the mouse every frame; we add a
-- render offset on top, which the game's positioning never resets. The offset is
-- worked out from the label's size, so it stays above the cursor even when tips or
-- resource costs make the label taller.
-- ============================================

local Mod = {}

-- ===== Config =====
-- Gap in pixels between the bottom of the label and the cursor tip.
local GAP_Y = 8
-- 0 = label centred over the cursor. Positive = shift right, negative = shift left.
local NUDGE_X = 0
-- How often to reposition the label (seconds). Lower = follows size changes faster.
local CHECK_INTERVAL = 0.1
-- Size used when the game can't tell us the label's size (pixels).
local FALLBACK_WIDTH = 48
local FALLBACK_HEIGHT = 32
-- How many position changes to write to the mod log (for tuning).
local MAX_LOG_LINES = 10

local WIDGET_CLASS_PATH = "/Game/Blueprints/UI/CommonUI/Game/W_FollowMouse.W_FollowMouse_C"

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

function Mod:GetWidgetClass()
    if not self._WidgetClass then
        pcall(function() self._WidgetClass = UE.UClass.Load(WIDGET_CLASS_PATH) end)
    end
    return self._WidgetClass
end

-- Returns width, height and where they came from. DesiredSize can be 0 before the
-- label has been laid out, so try the drawn size next, then the fallback.
function Mod:GetLabelSize(Widget)
    local ok, W, H = pcall(function()
        local Size = Widget:GetDesiredSize()
        return Size.X, Size.Y
    end)
    if ok and W and H and W > 1 and H > 1 then
        return W, H, "desired"
    end
    ok, W, H = pcall(function()
        local Size = UE.USlateBlueprintLibrary.GetLocalSize(Widget:GetCachedGeometry())
        return Size.X, Size.Y
    end)
    if ok and W and H and W > 1 and H > 1 then
        return W, H, "geometry"
    end
    return FALLBACK_WIDTH, FALLBACK_HEIGHT, "fallback"
end

-- ============================================
-- Core
-- ============================================

function Mod:ApplyOffset()
    local World = self:GetWorld()
    local WidgetClass = self:GetWidgetClass()
    if not World or not WidgetClass then
        return
    end

    local Widgets = UE.TArray(UE.UUserWidget)
    UE.UWidgetBlueprintLibrary.GetAllWidgetsOfClass(World, Widgets, WidgetClass, false)

    for i = 1, Widgets:Length() do
        local Widget = Widgets:Get(i)
        if Widget then
            local W, H, Source = self:GetLabelSize(Widget)
            local WantX = math.floor(-W / 2 + NUDGE_X + 0.5)
            local WantY = math.floor(-H - GAP_Y + 0.5)
            local Current = Widget.RenderTransform.Translation
            -- Size unknown (label briefly empty): keep the last good offset instead of
            -- jumping to the fallback size and back.
            local KeepCurrent = Source == "fallback" and (Current.X ~= 0 or Current.Y ~= 0)
            if not KeepCurrent and (Current.X ~= WantX or Current.Y ~= WantY) then
                Widget:SetRenderTranslation(UE.FVector2D(WantX, WantY))
                self._LogCount = (self._LogCount or 0) + 1
                if self._LogCount <= MAX_LOG_LINES then
                    self:Log(string.format("Label %dx%d (%s) -> offset (%d, %d)", W, H, Source, WantX, WantY))
                end
            end
        end
    end
end

-- ============================================
-- Lifecycle
-- ============================================

function Mod:OnModLoaded()
    self:Log("CursorLabelOffset loaded")
    self._TimerId = UE.UModLuaLibrary.RegisterModRepeatingTimer(nil, CHECK_INTERVAL, true, function()
        local ok, err = pcall(function() self:ApplyOffset() end)
        if not ok and not self._ErrorLogged then
            self._ErrorLogged = true
            self:Log("ApplyOffset error: " .. tostring(err))
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
