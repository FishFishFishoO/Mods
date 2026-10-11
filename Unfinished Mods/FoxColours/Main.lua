-- ============================================
-- FoxColours: spirit fox ears and tails in many colours for the sect outfit wardrobe.
-- Purely additive: only appends this mod's own IDs, never touches vanilla or other mods' entries.
-- ============================================

local Mod = {}

local FORCE_APPAREL_IDS = {
    Helmet = {
        "FoxColours_BlackFox_Ear",
        "FoxColours_WhiteFox_Ear",
        "FoxColours_GoldenFox_Ear",
        "FoxColours_RedFox_Ear",
        "FoxColours_OrangeFox_Ear",
        "FoxColours_SilverFox_Ear",
        "FoxColours_FrostFox_Ear",
        "FoxColours_NineTailFox_Ear", -- sect leader only (limited by SubClassApparelLimit = [0])
    },
    Pants = {
        "FoxColours_BlackFox_Tail",
        "FoxColours_WhiteFox_Tail",
        "FoxColours_GoldenFox_Tail",
        "FoxColours_RedFox_Tail",
        "FoxColours_OrangeFox_Tail",
        "FoxColours_SilverFox_Tail",
        "FoxColours_FrostFox_Tail",
        "FoxColours_NineTailFox_Tail", -- sect leader only (limited by SubClassApparelLimit = [0])
    },
}

function Mod:Log(Message, LogLevel)
    LogLevel = LogLevel or "Log"
    UE.UModLuaLibrary.ModLog(self.ModInfo.Metadata.ModId, Message, LogLevel)
end

function Mod:Warn(Message)
    self:Log(Message, "Warning")
end

function Mod:GetWorldFromSubsystem()
    local GI = UE.UGameplayStatics.GetGameInstance(self.ModInfo)
    if not GI then
        return nil
    end
    return GI:GetWorld()
end

local function ContainsID(Array, ID)
    for i = 1, Array:Length() do
        if tostring(Array:Get(i)) == ID then
            return true
        end
    end
    return false
end

function Mod:AddForceApparelIDs(ForceApparels, ArmorType, IDs)
    local ApparelConfig = ForceApparels:Find(ArmorType)
    if not ApparelConfig then
        ApparelConfig = UE.FNameIDArray()
    end
    for i = 1, #IDs do
        if not ContainsID(ApparelConfig.IDs, IDs[i]) then
            ApparelConfig.IDs:Add(IDs[i])
        end
    end
    ForceApparels:Add(ArmorType, ApparelConfig)
end

function Mod:ApplyForceApparels()
    local World = self:GetWorldFromSubsystem()
    if not World then
        self:Warn("ApplyForceApparels: no World, skipping")
        return false
    end
    local GameMode = UE.UGameplayStatics.GetGameMode(World)
    if not GameMode then
        self:Warn("ApplyForceApparels: no GameMode, skipping")
        return false
    end
    local ConfigComponent = GameMode.GameConfigComponent
    if not ConfigComponent then
        self:Warn("ApplyForceApparels: GameMode has no GameConfigComponent, skipping")
        return false
    end
    local Asset = ConfigComponent:GetGameDataAssetByType(UE.EGameDataAssetType.GamePlayConfiguration)
    if not Asset then
        self:Warn("ApplyForceApparels: GamePlayConfiguration asset is empty")
        return false
    end
    local ForceApparels = Asset.ForceApparels
    if not ForceApparels then
        self:Warn("ApplyForceApparels: asset has no ForceApparels")
        return false
    end

    self:AddForceApparelIDs(ForceApparels, UE.EArmorType.Helmet, FORCE_APPAREL_IDS.Helmet)
    self:AddForceApparelIDs(ForceApparels, UE.EArmorType.Pants, FORCE_APPAREL_IDS.Pants)

    self:Log("ApplyForceApparels: fox ears and tails added to sect outfits")
    return true
end

function Mod:OnModLoaded()
    self:Log("Mod loaded!")
    self:ApplyForceApparels()
end

function Mod:OnModUnloaded()
    self:Log("Mod unloaded!")
end

return Mod
