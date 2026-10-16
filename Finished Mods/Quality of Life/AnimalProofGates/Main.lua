-- ============================================
-- Animal-Proof Gates
-- Put a fence around your fields and animals can't get in anymore.
--
-- Fence gates stop animals (wild and tamed) while disciples and visitors walk through.
-- Three layers, all re-applied while you play:
--   1. Path finding: wooden and palisade fence gates get the house door's navigation box
--      (NavArea_Door) through the build table, and every animal gets the animal path
--      filter (BP_AnimalIdleNaviFilter), which won't path through doors. Wooden gates
--      already standing get the box right away.
--   2. Collision: each gate's door box (the trigger that opens it) blocks the animals'
--      collision channel ("Summons") and overlaps people's ("Character"). Animal capsules
--      near a gate are set to block "Door". The game resets those often, so they're
--      re-applied every 0.1 s.
--   3. Invisible wall: every 0.1 s, an animal standing on a gate's cells is put back
--      where it stood a moment earlier. This is the layer that holds.
-- Animals already inside a fence when the mod is turned on stay inside; take one gate
-- down for a moment to let them out.
-- Nothing is written to files.
-- ============================================

local Mod = {}

-- ===== Config =====
local VERSION = "1.0.0"
-- Rows (DT_Buildconfig) that get the house door's nav box through the table.
local NAV_ROWS = { "WoodFenceDoor", "WoodFenceDoor_2" }
-- Every gate row: these get the solid door box and the invisible wall.
local GATE_NAMES = {
    WoodFenceDoor = "wooden gates", WoodFenceDoor_2 = "palisade gates", BrickFenceDoor = "small courtyard gates",
    BrickFenceDoor_2 = "moon gates", BrickFenceGate = "grand gates",
}
local GATE_ORDER = { "WoodFenceDoor", "WoodFenceDoor_2", "BrickFenceDoor", "BrickFenceDoor_2", "BrickFenceGate" }
-- Build table row whose collision setup is copied (a wide house door).
local DOOR_ROW = "WoodDoorWide"
local DOOR_MESH_PATH = "/Game/Blueprints/Objects/SM_Building_Collision_Door.SM_Building_Collision_Door"
local DOOR_MESH_NAME = "SM_Building_Collision_Door"
local PLAIN_MESH_NAME = "SM_Building_Collision_Default"
-- The path filter animals normally use: it may not cross NavArea_Door.
local ANIMAL_FILTER_PATH = "/Game/Blueprints/Map/BP_AnimalIdleNaviFilter.BP_AnimalIdleNaviFilter_C"
-- Object channels from the game's DefaultEngine.ini.
local SUMMONS_CHANNEL = "ECC_GameTraceChannel3"   -- animals' capsules (profile "Summons")
local CHARACTER_CHANNEL = "ECC_GameTraceChannel8" -- people's capsules (profile "Character")
local DOOR_CHANNEL = "ECC_GameTraceChannel9"      -- gate door boxes (profile "Door")
local FAST_INTERVAL = 0.1
local SCAN_INTERVAL = 5.0
local SUMMARY_EVERY = 60
-- true = log a once-a-minute summary of what the mod did (for bug hunting).
local LOG_SUMMARY = false
-- Animals closer than this to a gate get their capsule re-blocked every FAST_INTERVAL.
local NEAR_GATE = 800
-- How far (cells) around a gate's position to look for its gate cells.
local GATE_SEARCH = 3

-- ============================================
-- Helpers
-- ============================================

function Mod:Log(Message)
    -- Only "error" level reliably reaches the game log.
    UE.UModLuaLibrary.ModLog(self.ModInfo.Metadata.ModId, Message, "error")
end

function Mod:LogOnce(Tag, Message)
    self._Logged = self._Logged or {}
    if not self._Logged[Tag] then
        self._Logged[Tag] = true
        self:Log(Message)
    end
end

function Mod:GetWorld()
    local GI = UE.UGameplayStatics.GetGameInstance(self.ModInfo)
    return GI and GI:GetWorld() or nil
end

local function Name(S)
    return UE.UKismetStringLibrary.Conv_StringToName(S)
end

local function ObjectName(Obj)
    if Obj == nil then
        return "nil"
    end
    local Text = nil
    pcall(function() Text = UE.UKismetSystemLibrary.GetObjectName(Obj) end)
    return Text or tostring(Obj)
end

local function SoftText(Soft)
    local Text = nil
    pcall(function() Text = UE.UKismetSystemLibrary.Conv_SoftObjectReferenceToString(Soft) end)
    return Text or tostring(Soft)
end

local function GuidText(Guid)
    local Text = nil
    pcall(function() Text = UE.UKismetGuidLibrary.Conv_GuidToString(Guid) end)
    return Text or "?"
end

local function CellKey(Row, Col)
    return tostring(Row) .. "," .. tostring(Col)
end

-- UnLua hands out parameters back as return values; some builds also fill the struct
-- passed in. Use the returned one when there is one.
local function OutOr(Ret, Passed)
    if Ret ~= nil and type(Ret) ~= "boolean" and type(Ret) ~= "number" then
        return Ret
    end
    return Passed
end

local function ResponseName(Value)
    for _, N in ipairs({ "ECR_Ignore", "ECR_Overlap", "ECR_Block" }) do
        local ok, V = pcall(function() return UE.ECollisionResponse[N] end)
        if ok and V == Value then
            return N:sub(5)
        end
    end
    return tostring(Value)
end

-- Collision setup of a component towards one channel, for the log.
local function CollisionText(Comp, Channel)
    local Profile, Response, Enabled = "?", "?", "?"
    pcall(function() Profile = tostring(Comp:GetCollisionProfileName()) end)
    pcall(function() Response = ResponseName(Comp:GetCollisionResponseToChannel(UE.ECollisionChannel[Channel])) end)
    pcall(function() Enabled = tostring(Comp:GetCollisionEnabled()) end)
    return string.format("profile %s, collision %s, %s -> %s", Profile, Enabled, Channel, Response)
end

-- Sets Comp's response to Channel ("ECR_Block" etc). Returns "set", "already" or
-- "did not stick".
local function SetResponse(Comp, Channel, Response)
    local Ch = UE.ECollisionChannel[Channel]
    local Want = UE.ECollisionResponse[Response]
    if Comp:GetCollisionResponseToChannel(Ch) == Want then
        return "already"
    end
    Comp:SetCollisionResponseToChannel(Ch, Want)
    return Comp:GetCollisionResponseToChannel(Ch) == Want and "set" or "did not stick"
end

-- Moves a character without sweeping (K2_TeleportTo returned false in game). Returns
-- true if it moved.
local function Teleport(Char, Location)
    local Moved = false
    pcall(function() Moved = Char:K2_SetActorLocation(Location, false, UE.FHitResult(), true) == true end)
    return Moved
end

function Mod:Table(World, Type)
    local GameMode = UE.UGameplayStatics.GetGameMode(World)
    local Comp = GameMode and GameMode.GameConfigComponent
    local DT = Comp and Comp:GetGameConfigByType(Type)
    if DT and DT:IsValid() then
        return DT
    end
    return nil
end

-- ============================================
-- 1. Path finding: build table, gates' nav box, animals' path filter
-- ============================================

-- Copies the house door's collision setup into the NAV_ROWS. Runs once per table.
function Mod:PatchTable(World)
    local DT = self:Table(World, UE.EGameConfigType.BuildConfig)
    if not DT or self._PatchedTable == DT then
        return
    end
    self._PatchedTable = DT
    local Door = UE.FBuildConfigData()
    if not UE.UDataTableFunctionLibrary.GetDataTableRowFromName(DT, Name(DOOR_ROW), Door) then
        self:Log("table: no " .. DOOR_ROW .. " row to copy the door box from, table not changed")
        return
    end
    for _, RowName in ipairs(NAV_ROWS) do
        local Row = UE.FBuildConfigData()
        if UE.UDataTableFunctionLibrary.GetDataTableRowFromName(DT, Name(RowName), Row) then
            local Before = string.format("%s, %s, default box %s", SoftText(Row.CollisionMesh),
                tostring(Row.CompleteCollisionProfileName), tostring(Row.UseDefaultMesh))
            Row.CollisionMesh = Door.CollisionMesh
            Row.CompleteCollisionProfileName = Door.CompleteCollisionProfileName
            Row.UseDefaultMesh = Door.UseDefaultMesh
            local Replaced = UE.UModLuaLibrary.ReplaceDataTableRow(DT, Name(RowName), Row)
            local Check = UE.FBuildConfigData()
            UE.UDataTableFunctionLibrary.GetDataTableRowFromName(DT, Name(RowName), Check)
            if not Replaced or SoftText(Check.CollisionMesh) ~= SoftText(Door.CollisionMesh) then
                self:Log(string.format("table: could not change %s (was %s, now %s)", RowName, Before,
                    SoftText(Check.CollisionMesh)))
            end
        else
            self:Log("table: no row " .. RowName)
        end
    end
end

function Mod:DoorMesh()
    if not self._DoorMesh then
        pcall(function() self._DoorMesh = UE.UObject.Load(DOOR_MESH_PATH) end)
        if not self._DoorMesh then
            self:LogOnce("no_mesh", "could not load " .. DOOR_MESH_PATH)
        end
    end
    return self._DoorMesh
end

-- Gives one gate the door's nav box if it still has the plain one (wooden gates loaded
-- before the table was patched). Returns "swapped", "door-type" or "not door-type".
function Mod:FixGateNav(Actor)
    local Comps = Actor:K2_GetComponentsByClass(UE.UStaticMeshComponent)
    local Result = "not door-type"
    for i = 1, Comps:Length() do
        local Comp = Comps:Get(i)
        local Instanced = false
        pcall(function() Instanced = Comp:IsA(UE.UInstancedStaticMeshComponent) end)
        if not Instanced then
            local MeshName = ObjectName(Comp.StaticMesh)
            if MeshName == DOOR_MESH_NAME and Result == "not door-type" then
                Result = "door-type"
            elseif MeshName == PLAIN_MESH_NAME then
                local Mesh = self:DoorMesh()
                if Mesh then
                    Comp:SetStaticMesh(Mesh)
                    -- Make the navigation mesh pick up the new area right away.
                    pcall(function()
                        Comp:SetCanEverAffectNavigation(false)
                        Comp:SetCanEverAffectNavigation(true)
                    end)
                    Result = "swapped"
                end
            end
        end
    end
    return Result
end

function Mod:AnimalFilter()
    if not self._AnimalFilter then
        pcall(function() self._AnimalFilter = UE.UClass.Load(ANIMAL_FILTER_PATH) end)
        if not self._AnimalFilter then
            self:LogOnce("no_filter", "could not load " .. ANIMAL_FILTER_PATH)
        end
    end
    return self._AnimalFilter
end

-- ============================================
-- 2. Collision: gate door boxes and animal capsules
-- ============================================

-- Door box: block animals (Summons), overlap people (Character) so they still open it.
-- Returns "set", "already", "no door box" or "did not stick".
function Mod:FixDoorBox(Actor, RowName)
    local Box = Actor.DoorCollisionComponent and Actor.DoorCollisionComponent.DoorCollision
    if not Box then
        return "no door box"
    end
    local Before = CollisionText(Box, SUMMONS_CHANNEL) .. "; " .. CollisionText(Box, CHARACTER_CHANNEL)
    local A = SetResponse(Box, SUMMONS_CHANNEL, "ECR_Block")
    local B = SetResponse(Box, CHARACTER_CHANNEL, "ECR_Overlap")
    local Result = (A == "did not stick" or B == "did not stick") and "did not stick"
        or ((A == "set" or B == "set") and "set" or "already")
    if Result == "did not stick" then
        self:LogOnce("box_" .. RowName, string.format("%s door box did not change: was %s; now %s; %s", RowName,
            Before, CollisionText(Box, SUMMONS_CHANNEL), CollisionText(Box, CHARACTER_CHANNEL)))
    end
    return Result
end

-- Animal capsule: block "Door". Returns "set", "already" or "did not stick".
function Mod:FixCapsule(Char)
    local Capsule = Char.CapsuleComponent
    if not Capsule then
        return "no capsule"
    end
    return SetResponse(Capsule, DOOR_CHANNEL, "ECR_Block")
end

-- ============================================
-- 3. Gate cells (for the invisible wall)
-- ============================================

function Mod:ToGrid(Location)
    local G = self._Grid or { Size = 100, OX = 0, OY = 0 }
    -- Rows run along Y and columns along X (checked against the game in FencedFieldsProbe).
    return math.floor((Location.Y - G.OY) / G.Size), math.floor((Location.X - G.OX) / G.Size)
end

function Mod:IsGateCell(MapData, Row, Col)
    local GP = UE.FGridPosition()
    GP.Row = Row
    GP.Column = Col
    local Cell = UE.FGridData()
    Cell = OutOr(MapData:GetGridData(GP, Cell), Cell)
    local FenceGate = UE.EEnvironType.FenceGate
    local Layers = Cell.LayerData:Keys()
    for l = 1, Layers:Length() do
        local Env = Cell.LayerData:Find(Layers:Get(l))
        if Env and Env.EnvironData:Find(FenceGate) ~= nil then
            return true
        end
    end
    return false
end

-- The cells of one gate: FenceGate cells near the gate's position, plus the FenceGate
-- cells connected to them. Returns a list of { Row, Col }.
function Mod:GateCellsOf(MapData, Actor)
    local Row, Col = self:ToGrid(Actor:K2_GetActorLocation())
    local Cells, Seen, Queue = {}, {}, {}
    -- Seeds: gate cells right next to the gate's position, or else anywhere in the window.
    for _, Reach in ipairs({ 1, GATE_SEARCH }) do
        if #Queue == 0 then
            for DR = -Reach, Reach do
                for DC = -Reach, Reach do
                    local Key = CellKey(Row + DR, Col + DC)
                    if not Seen[Key] then
                        Seen[Key] = true
                        if self:IsGateCell(MapData, Row + DR, Col + DC) then
                            table.insert(Queue, { Row + DR, Col + DC })
                        end
                    end
                end
            end
        end
    end
    -- Cells checked while seeding but not gate cells may still join through a neighbour.
    for Key in pairs(Seen) do
        Seen[Key] = nil
    end
    for _, C in ipairs(Queue) do
        Seen[CellKey(C[1], C[2])] = true
    end
    local Head = 1
    while Head <= #Queue and #Cells < 64 do
        local C = Queue[Head]
        Head = Head + 1
        table.insert(Cells, C)
        for _, D in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            local R, Co = C[1] + D[1], C[2] + D[2]
            local Key = CellKey(R, Co)
            if not Seen[Key] then
                Seen[Key] = true
                if self:IsGateCell(MapData, R, Co) then
                    table.insert(Queue, { R, Co })
                end
            end
        end
    end
    return Cells
end

-- ============================================
-- Scan (every SCAN_INTERVAL): gates, gate cells, animals
-- ============================================

-- Calls Visit(Actor, Guid, RowName, MapData) for every finished gate.
function Mod:ForEachGate(World, Visit)
    local Places = UE.TArray(UE.AWorldPlace)
    UE.UGameplayStatics.GetAllActorsOfClass(World, UE.AWorldPlace, Places)
    for p = 1, Places:Length() do
        local MapData = Places:Get(p).MapDataMgr
        if MapData then
            local All = MapData:GetMapBuildingData()
            for i = 1, All:Length() do
                local Data = All:Get(i)
                local RowName = tostring(Data.BuildConfigId)
                if GATE_NAMES[RowName] then
                    for b = 1, Data.BuildIds:Length() do
                        local Guid = Data.BuildIds:Get(b)
                        local Actor = MapData:FindObject(Guid)
                        if Actor then
                            Visit(Actor, GuidText(Guid), RowName, MapData)
                        end
                    end
                end
            end
        end
    end
end

function Mod:ScanGates(World)
    local Counts, GateCells, Gates = {}, {}, {}
    local CellCount = 0
    self:ForEachGate(World, function(Actor, Guid, RowName, MapData)
        if not self._Grid then
            pcall(function()
                self._Grid = { Size = MapData.GridLength, OX = MapData.LandscapeOrigin.X, OY = MapData.LandscapeOrigin.Y }
            end)
        end
        local C = Counts[RowName] or { Total = 0, Nav = {}, Box = {} }
        Counts[RowName] = C
        C.Total = C.Total + 1
        local NavOk, Nav = pcall(function() return self:FixGateNav(Actor) end)
        Nav = NavOk and Nav or "nav error"
        C.Nav[Nav] = (C.Nav[Nav] or 0) + 1
        local BoxOk, Box = pcall(function() return self:FixDoorBox(Actor, RowName) end)
        if not BoxOk then
            self:LogOnce("box_err", "door box error: " .. tostring(Box))
            Box = "box error"
        end
        C.Box[Box] = (C.Box[Box] or 0) + 1
        local CellsOk, Cells = pcall(function() return self:GateCellsOf(MapData, Actor) end)
        if not CellsOk then
            self:LogOnce("cells_err", "gate cell error: " .. tostring(Cells))
            Cells = {}
        end
        if #Cells == 0 then
            self:LogOnce("nocells_" .. Guid, string.format("%s at %s: no gate cells found nearby", GATE_NAMES[RowName],
                CellKey(self:ToGrid(Actor:K2_GetActorLocation()))))
        end
        local Center = Actor:K2_GetActorLocation()
        table.insert(Gates, { Center = Center, Kind = GATE_NAMES[RowName] })
        for _, Cell in ipairs(Cells) do
            local Key = CellKey(Cell[1], Cell[2])
            if not GateCells[Key] then
                CellCount = CellCount + 1
            end
            GateCells[Key] = #Gates
        end
    end)
    self._GateCells, self._Gates = GateCells, Gates

    local Parts = {}
    for _, RowName in ipairs(GATE_ORDER) do
        local C = Counts[RowName]
        if C then
            local Nav, Box = {}, {}
            for K, V in pairs(C.Nav) do
                table.insert(Nav, K .. " x" .. V)
            end
            for K, V in pairs(C.Box) do
                table.insert(Box, K .. " x" .. V)
            end
            table.sort(Nav)
            table.sort(Box)
            table.insert(Parts, string.format("%d %s (nav: %s; door box: %s)", C.Total, GATE_NAMES[RowName],
                table.concat(Nav, ", "), table.concat(Box, ", ")))
        end
    end
    local Summary = string.format("gates: %s; %d gate cells walled off for animals",
        #Parts > 0 and table.concat(Parts, "; ") or "none", CellCount)
    if Summary ~= self._LastGateSummary then
        self:Log(Summary)
    end
    self._LastGateSummary = Summary
end

-- Refreshes the animal list, gives every animal the path filter and the capsule block.
function Mod:ScanAnimals(World)
    local Filter = self:AnimalFilter()
    local Animals = {}
    local Controllers = UE.TArray(UE.AEastRimWorldAIController)
    UE.UGameplayStatics.GetAllActorsOfClass(World, UE.AEastRimWorldAIController, Controllers)
    for i = 1, Controllers:Length() do
        local ok, err = pcall(function()
            local Controller = Controllers:Get(i)
            local Char = Controller.ControlledCharacter
            if not Char then
                return
            end
            local Type = Char:GetCharacterType()
            if Type ~= UE.ECharacterType.Animal then
                return
            end
            local Tamed = false
            pcall(function() Tamed = Char:IsPlayerTeam() == true end)
            table.insert(Animals, { Controller = Controller, Char = Char, Name = ObjectName(Char), Tamed = Tamed })
            if Filter and ObjectName(Controller.FilterClass) ~= ObjectName(Filter) then
                Controller.FilterClass = Filter
                self._Stats.Filters = self._Stats.Filters + 1
            end
            if self:FixCapsule(Char) == "set" then
                self._Stats.Reblocks = self._Stats.Reblocks + 1
            end
        end)
        if not ok then
            self:LogOnce("animal_err", "animal error: " .. tostring(err))
        end
    end
    self._Animals = Animals
end

-- ============================================
-- Invisible wall (every FAST_INTERVAL)
-- ============================================

function Mod:NearGate(Location)
    local Limit = NEAR_GATE * NEAR_GATE
    for _, G in ipairs(self._Gates or {}) do
        local DX, DY = Location.X - G.Center.X, Location.Y - G.Center.Y
        if DX * DX + DY * DY < Limit then
            return true
        end
    end
    return false
end

function Mod:Wall()
    local GateCells = self._GateCells
    if not GateCells or not self._Animals then
        return
    end
    local S = self._Stats
    self._Safe = self._Safe or {}
    for _, A in ipairs(self._Animals) do
        local ok, err = pcall(function()
            local Loc = A.Char:K2_GetActorLocation()
            local Row, Col = self:ToGrid(Loc)
            local Gate = GateCells[CellKey(Row, Col)]
            if Gate then
                local Safe = self._Safe[A.Name]
                if Safe then
                    Teleport(A.Char, Safe)
                    pcall(function() A.Controller:StopMovement() end)
                    S.Bounces = S.Bounces + 1
                    if A.Tamed then
                        S.TamedBounces = S.TamedBounces + 1
                    end
                else
                    S.NoSafe = S.NoSafe + 1
                end
            else
                self._Safe[A.Name] = Loc
                if self:NearGate(Loc) and self:FixCapsule(A.Char) == "set" then
                    S.Reblocks = S.Reblocks + 1
                end
            end
        end)
        if not ok then
            self:LogOnce("wall_err", "wall error: " .. tostring(err))
        end
    end
end

-- Resets the counters (kept for debugging; set LOG_SUMMARY to true to log them).
function Mod:LogSummary()
    local S = self._Stats
    if LOG_SUMMARY and S.Bounces + S.Reblocks + S.NoSafe + S.Filters > 0 then
        self:Log(string.format("last %d s: %d animals put back from a gate (%d tamed), %d capsules re-blocked, %d path filters reset, %d times an animal stood on a gate with no earlier spot",
            SUMMARY_EVERY, S.Bounces, S.TamedBounces, S.Reblocks, S.Filters, S.NoSafe))
    end
    self._Stats = { Bounces = 0, TamedBounces = 0, Reblocks = 0, Filters = 0, NoSafe = 0 }
end

-- ============================================
-- Lifecycle
-- ============================================

function Mod:OnModLoaded()
    self:Log(string.format("Animal-Proof Gates %s loaded", VERSION))
    self._Stats = { Bounces = 0, TamedBounces = 0, Reblocks = 0, Filters = 0, NoSafe = 0 }
    local SinceScan, SinceSummary = SCAN_INTERVAL, 0
    self._TimerId = UE.UModLuaLibrary.RegisterModRepeatingTimer(nil, FAST_INTERVAL, true, function()
        local ok, err = pcall(function()
            local World = self:GetWorld()
            if not World then
                return
            end
            -- Patch the table as early as possible, before a save's gates are built.
            if not self._PatchedTable then
                self:PatchTable(World)
            end
            SinceScan = SinceScan + FAST_INTERVAL
            if SinceScan >= SCAN_INTERVAL then
                SinceScan = 0
                self:PatchTable(World)
                self:ScanGates(World)
                self:ScanAnimals(World)
            end
            self:Wall()
            SinceSummary = SinceSummary + FAST_INTERVAL
            if SinceSummary >= SUMMARY_EVERY then
                SinceSummary = 0
                self:LogSummary()
            end
        end)
        if not ok then
            self._Errors = (self._Errors or 0) + 1
            if self._Errors <= 3 then
                self:Log("error: " .. tostring(err))
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
