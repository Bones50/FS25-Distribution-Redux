-- ============================================================================
-- DistributionHelpDialog.lua  (Distribution Redux)
-- Single source of truth for the in-game User Guide. The menu's User Guide tab
-- (DistributionHelpPage) renders DistributionHelpDialog.TOPICS via .buildLines,
-- so editing the TOPICS table below updates the guide everywhere.
--
--   left  list (topicList) : the table of contents
--   right list (bodyList)  : the selected topic's text, word-wrapped to rows
--
-- Both lists share this frame as their delegate; the delegate methods tell them
-- apart by identity (list == self.topicList vs self.bodyList). Content is held
-- inline as plain text so there is no XML/l10n dependency at display time.
--
-- In a topic body, a line beginning with "## " renders as a sub-heading and a
-- blank line is a spacer; never write two consecutive close-brackets in a body.
-- ============================================================================

DistributionHelpDialog = {}
local Dlg_mt = Class(DistributionHelpDialog, MessageDialog)

local WRAP_CHARS = 70     -- character-based word wrap width for the content pane

-- ---- guide content ---------------------------------------------------------
-- Each topic: { title = <string>, body = <text> }.  In the body, a line that
-- begins with "## " is rendered as a sub-heading; blank lines are spacers.
local TOPICS = {
    {
        title = "Getting Started",
        body = [[
Distribution Redux replaces the base-games distribution system with a demand-driven system and extends that system to additional buildings such as animal husbandry, silo's/storage and markets. Each in-game hour it determines the expected demand and only feeds what that production needs. Excess stock can be sold, or stored in a suitable building after distribution. No extra placeables needed, works on all default buildings as well as building mods that stick with the standard Giants schema for that building type. 

## Two keys
Backslash key: open the Distribution Redux menu - a full-screen window with a tab for every kind of building, plus this guide and the settings.
Left-bracket key: while on foot, look at a building's loading or unloading point to open the menu straight to that building's page. The prompt only appears when you are looking at one of your own buildings that is part of the network.
Both keys can be rebound under Options - Controls.

## The idea
Open the menu, pick the building you care about, and set each product to Hold, Distribute, Sell, and so on. That is the whole loop - everything else is detail.]]
    },
    {
        title = "The Menu",
        body = [[
The backslash key opens the consolidated menu. Down the left side are tabs.

## Tabs
Productions - factories and production points.
Silos - bulk silos and pallet / bale storage sheds.
Animal Husbandry - barns, coops, beehives, plus manure and slurry pits.
Markets - Kiosks and Markets you place on the map.
User Guide - this guide.
Settings - the global options.

Each building tab is a two-pane page: your buildings listed on the left, and the selected building's inputs, production lines and outputs (Varies depending on the building function) on the right.

## Hidden tabs
The Silos/Storage, Animal Husbandry, and Markets tabs only appear when that group is switched on in Settings. If you have excluded silos and pallet storage, animal husbandry, or markets, the matching tab is hidden and those buildings are removed from the distribution network - turn the group back on to see it again.]]
    },
    {
        title = "Building Pages",
        body = [[
The Productions, Silos, Markets and Animal Husbandry tabs share one layout: pick a building on the left, configure its production lines and products on the right. Where applicable it will show inputs, Production lines and outputs and allow you to adjust where each product goes (as well as activate or deactivate production lines).

## Columns
Product - the name and icon.
Held / Stock - how much is in the building now.
Distr. / mo - litres distributed in the last in-game month (24 hours).
Sold / mo - litres sold in the last in-game month (24 hours). Value of sale is shown in brackets.
Stored / mo - litres pushed into storage and markets in the last in-game month (24 hours).
Mode - the product's current output mode (and, for selling, its sell timing).

## Setting a mode
Cycle the output in the list and use the cycle output button to step it through the available modes, or cycle the whole building at once. Highlight a production line to turn it on or off.

If you select a sell mode, click the Sell Timing button to switch between sell immediately or sell at best price.

Changing a production output or turning a production line on or off here is the same setting as the vanilla production screen's output toggle, so either place updates the other - and the vanilla screen shows the mod's mode names too.]]
    },
    {
        title = "Output Modes",
        body = [[
A mode tells the mod what to do with a product, or a production output, each hour. The names read the same on the production screen and in the mod's pages.

## Hold / Hold Pallets / Hold Internal
Leave the output where it is - the mod will not move or sell it. Most products simply show "Hold" (this was called "Stored" in earlier versions).

A production output that can be made into pallets instead shows two choices:
Hold Pallets - the production keeps dropping pallets automatically as it fills, exactly like the base game.
Hold Internal - the output is kept as bulk inside the production and no pallets spawn on their own; you spawn them yourself on demand (see Pallet Spawning).

## Distribute
Feed nearby productions and animals that need this product, nearest source first, up to what their recipes call for. Surplus stays put.

## Sell
Sell it each hour - immediately, or once it reaches its best price (see Sell Timing).

## Distribute + Sell
Feed demand first, then sell whatever is left over (See Sell timing and Annual Harvest Reserve for details on how these features work).

## Distribute + Store
Feed demand first, then move the surplus into your other storage (silos and sheds) instead of selling it. Productions and barns only.

## Store
Do not distribute at all; move the whole product straight into your other storage. Use it to funnel everything to one central store or silo. Productions and barns only.

## Market Supply
Transfers outputs to a market/kiosk you have placed. From there the product can be sold at a premium price.

## Distribute + Market Supply
Feed demand first, then transfers outputs to a market/kiosk you have placed.

#Advanced Features

## Sell Timing
Anything set to Sell or Distribute + Sell can either sell straight away or wait for a good price.
Immediate - Sell the surplus each hour at whatever the current price is. Simple and steady.
Best price - Hold the surplus back and only sell when the price is at, or near, the top of its cycle. The mod reads the season's price curve for each crop and waits for the peak, so you earn more per litre at the cost of selling less often.

## Annual Harvest Reserve
If activated in the settings the Annual Harvest Reserve will identify crops that come in annually and each cycle it will determine how much stock it needs to keep until the next harvest cycle comes around. This prevents modes that store, move or sell surplus from actiong on stock needed to keep the production going for the entire year.

## Water Supply
If activated in the settings Water will automatically be supplied to any buildings that need it (e.g. Animal Husbandry, Greenhouses etc). The system will calculate the cost using the standard formula, but identifying the closest water source (either a water tank OR a lake) to determine distance.]]
    },
    {
        title = "Pallet Spawning",
        body = [[
Many production outputs can be turned into pallets (boards, planks, vegetables in crates, and so on). Distribution Redux lets you keep those outputs as bulk and spawn pallets by hand, only when you want them, instead of the production dropping them automatically.

## Hold Internal
On the Productions tab (or the base-game production screen), set a palletisable output to Hold Internal. The production then keeps that output as bulk stock and stops dropping pallets on its own. The stock simply builds up in the building until you distribute, sell, move, or spawn it.

## Spawning pallets
Once a Hold Internal output holds at least one pallet's worth of stock, a Spawn Pallets button appears - both on the Distribution Redux Productions tab and on the base-game production screen. Press it to open the spawn window.

## The spawn window
Type - the pallet type. If the output only supports one type it is shown for reference; if it supports more, use the arrows to choose.
Quantity - how many pallets to spawn. The arrows step by one, the -10 / +10 buttons jump in tens, and the amount is capped at what the held stock allows.
Spawn drops that many filled pallets at the production's pallet point and removes the matching amount of stock. Cancel closes without spawning.

## Good to know
The button only shows for an output that is on Hold Internal and has at least one full pallet's worth stored - below that, there is nothing to spawn.
The production must have a pallet spawn point in its model (most palletising buildings do).
In multiplayer the host performs the spawn, so the pallets appear for every player.]]
    },
    {
        title = "The Hourly Pass",
        body = [[
Once an in-game hour, on the host, the mod runs a single tidy pass in three steps.

## 1. Feed and water
It looks at every active production line and enrolled animal pen, works out what they need, and pulls those inputs from buildings set to a Distribute mode - nearest source first. Anything needing water is topped up at the same time. It sends a buffer, not a flood: a consumer is topped up to about the buffer hours of feedstock (default 2 hours), so one factory cannot vacuum up the whole farm.

## 2. Store the surplus
Distribute + Store outputs push their leftover into storage, and Store pushes everything in - nearest store first, overflowing to the next. This happens after feeding, so storing never grabs stock a factory still needed.

## 3. Send the surplus to my Market/Kiosk
Market Supply and Distribute + Market Supply outputs are transferred to any markets you have placed, also only after feeding

## 3. Sell the surplus
Sell and Distribute + Sell outputs are sold, also only after feeding - a sale never beats a hungry consumer to the stock. With Best price timing a sale waits for the price peak, and an optional seasonal reserve can hold back enough feedstock to last until the next harvest.]]
    },
    {
        title = "Distribution Costs",
        body = [[
By default, moving goods is not free - the mod charges a small per-hour distribution cost for each active delivery link (feeding, storing offsite, and watering all count), to stop teleport-everything-everywhere from being a no-brainer. The charge appears under your farm's maintenance and upkeep.

## How it is calculated
The cost for one link each hour is the base cost times x the distance in increments (Threshold), with a base of 10 and a threshold of 50 m by default. A delivery within 50 m costs the flat base; one at 150 m costs three times the base. Water is billed the same way. Costs are summed per farm each hour.

You can lower the base, change the threshold, or switch the whole thing off in Settings - turning it off makes watering free too.]]
    },
    {
        title = "What Takes Part",
        body = [[
You decide which buildings join the network with three settings on the Settings tab.

## Scope
Range - every eligible building takes part, across the whole farm. The most hands-off option.
Proximity - eligible buildings take part, but a source only reaches consumers within a radius (default 50 m).

## Animal Husbandry (on / off)
Includes or excludes barns, coops, beehives, and manure and slurry pits. Off removes them entirely - they are neither fed nor is their output distributed or sold, and their tab is hidden.

## Silos & Pallet Storage (on / off)
Includes or excludes bulk silos and pallet / bale storage sheds. Off removes them - silos stop feeding productions and sheds neither receive nor release pallets, and their tab is hidden.

## Markets and Kiosks (on / off)
Includes or excludes Markets and Kiosks. Off removes them - Markets cannot be fed products, and their tab is hidden.

## Productions
Productions always take part, exactly as in the base game - there is no switch to exclude them.]]
    },
    {
        title = "Settings",
        body = [[
Global settings live on the Settings tab. They are saved with your profile and synced in multiplayer by the host. Per-building choices you make on a building's page always override these globals for that building.

## The options
Scope - Range (whole farm) or Proximity (within a radius).
Animal Husbandry - include or exclude barns, coops, beehives and manure / slurry pits.
Silos & Pallet Storage - include or exclude bulk silos and pallet / bale sheds.
Markets & Kiosks - include or exclude Markets and Kiosks.
Proximity radius - how far a source reaches in Proximity scope.
Consumer buffer - hours of feedstock topped up at each consumer per cycle.
Sell at best price - master on / off for selling at best price (otherwise reverts just to sell immediately).
Default Sell Timing - default sell timing: wait for the price peak, or sell immediately.
Auto-Water - automatically supply water to water-input productions and pastures.
Distribution cost / rate / distance - the per-hour transport cost and how it scales.
Seasonal harvest reserve - keep enough feedstock to feed production until the next harvest, selling only the surplus.
Harvest Reserve months - Initially the system will not know when you harvest your seasonal products, lacking that information the system will default to keeping this many months of product until it learns better. 
Debug logging - write detailed activity to log.txt; turn off for a quieter log.]]
    },
    {
        title = "Troubleshooting",
        body = [[
A building is not showing up? Check Scope and the group toggles - Proximity only reaches within the radius, and a building whose group (Animal Husbandry, or Silos & Pallet Storage) is switched off is removed from the network and its tab hidden.

Nothing is being delivered? Make sure the source is set to a Distribute mode (not Hold), the consumer's production line is active, and the two are within reach for the current scope.

A factory is not getting water? Water is supplied automatically when Auto-Water is on; if a water-input plant looks starved, confirm the setting.

No prompt at a building? The left-bracket prompt only shows for buildings that are part of the network. If you excluded that group in Settings, the prompt is gone by design.

Do not run it alongside other distribution-overhaul mods - they hook the same system and will fight. The mod works on base-game buildings and any modded buislings that follow Giants standard Schema; some modded buildings may behave differently.]]
    },
    {
        title = "Changelog",
        body = [[
## v1.0.0.2
1. Renaming buildings - every building in the distribution network can now be given a custom name from the base-game construction menu. The game only allows this on some buildings by default; Distribution Redux enables it for all of its buildings (silos, sheds, pits and markets included). The mod then uses your name everywhere in this menu, with the original building name shown underneath it as a reference, so a farm with eight identical greenhouses is finally readable.
2. Manure Heap / Slurry Pit product fix - each was listing the other's product as an output. The Manure Heap now shows only Manure, and the Slurry Pit only Slurry.
3. Manure Heap / Slurry Pit incoming fix - neither showed an incoming product. They now list what actually flows into them (manure and slurry respectively).

## v1.0.0.1
1. UI Improvements and consistency pass including addition of scroll bars, repositioning of tables, Added the value of products sold in the last month to the sold/mo column etc
2. Added Markets and Kiosks to the distribution system - All buildings now have a market supply option to route the output to a market you have placed. Items sold through your market get a 20% bonus to price although selling in bulk will reduce the price you get (just like base game).
3. Sell at Best Price Fix - When set to sell at best price and the system has no pricing history, product would sell earlier than expected. Now falls back to the price graph in game if it doesn't have enough of it's own data.
4. Added Hold Internal mode and manual pallet spawning - palletisable production outputs can be kept as bulk stock (Hold Internal) instead of auto-spawning pallets, then spawned by hand on demand through a spawn window where you pick the pallet type and quantity. Available from both the Distribution Redux Productions tab and the base-game production screen.

## v1.0.0.0
1. Added the ability to specify whether goods should sell immediately or once they hit best price.
2. Completely rebuilt UI that breaks out distribution types and consolidates the settings and help guide into the menu.
3. Fixes to silo extensions so they work in a consistent manner. An extension must now be placed within the vicinity of a matching silo type; all distribution is managed in the primary silo and the extension simply adds storage to it.
4. Pallet and bale sheds now display all active pallets in the network so they can be pre-configured before items arrive. Added a reserve function that sells pallets (least valuable first) to keep space free for the next cycle - bypassed if another pallet shed has space, in which case pallets are moved there instead.
5. Pallet shed interaction fixed: look at the loading-point icon in-game to open that building's distribution page directly.
6. Fixed a small amount of output being left in the source after distribution (a timing issue).
7. Biogas plant fixed: methane and electrical charge sales now take game difficulty into account, and digestate now properly registers as Biogas Plant income on the finance sheet.
8. Settings reworked to be more granular: you can now include or exclude silos / pallet sheds, and include or exclude animal husbandry buildings. Productions always register and participate in distribution, just like the base game.
9. Change in mode titles: Hold now holds items in the building (used to be "Stored"); Store moves items offsite when storage is available.

## v0.0.0.1
Pre-Release.]]
    },
}

-- ---- word wrap -------------------------------------------------------------

DistributionHelpDialog.TOPICS = TOPICS

-- Turn a topic body into an ordered list of display rows:
--   { text = <string>, head = <bool> }
-- "## " paragraphs become sub-headings; blank lines become spacer rows.
local function wrapParagraph(text, maxChars, isHead, out)
    local line = ""
    for word in text:gmatch("%S+") do
        if line == "" then
            line = word
        elseif #line + 1 + #word <= maxChars then
            line = line .. " " .. word
        else
            out[#out + 1] = { text = line, head = isHead }
            line = word
        end
    end
    if line ~= "" then out[#out + 1] = { text = line, head = isHead } end
end

local function buildLines(body, maxChars)
    maxChars = maxChars or WRAP_CHARS
    local out = {}
    -- iterate paragraphs (split on newline), keeping blank lines as spacers
    for paragraph in (body .. "\n"):gmatch("(.-)\n") do
        if paragraph == "" then
            out[#out + 1] = { text = "", head = false }
        elseif paragraph:sub(1, 3) == "## " then
            local heading = paragraph:sub(4)
            out[#out + 1] = { text = "", head = false }                 -- spacer above heading
            wrapParagraph(heading:upper(), maxChars, true, out)
        else
            wrapParagraph(paragraph, maxChars, false, out)
        end
    end
    return out
end

DistributionHelpDialog.buildLines = buildLines

-- ---- frame -----------------------------------------------------------------
function DistributionHelpDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or Dlg_mt)
    self.currentTopic = 1
    self.lines = {}
    return self
end

function DistributionHelpDialog:onGuiSetupFinished()
    DistributionHelpDialog:superClass().onGuiSetupFinished(self)
    if self.topicList ~= nil then
        self.topicList:setDataSource(self)
        self.topicList:setDelegate(self)
    end
    if self.bodyList ~= nil then
        self.bodyList:setDataSource(self)
        self.bodyList:setDelegate(self)
    end
end

function DistributionHelpDialog:selectTopic(index)
    if index == nil or TOPICS[index] == nil then return end
    self.currentTopic = index
    self.lines = buildLines(TOPICS[index].body)
    if self.bodyTitleElement ~= nil then
        self.bodyTitleElement:setText((TOPICS[index].title or ""):upper())
    end
    if self.bodyList ~= nil then self.bodyList:reloadData() end
end

function DistributionHelpDialog:onOpen()
    DistributionHelpDialog:superClass().onOpen(self)

    if self.dialogTitleElement ~= nil then
        self.dialogTitleElement:setText("Distribution Redux")
    end

    if self.topicList ~= nil then self.topicList:reloadData() end
    self:selectTopic(self.currentTopic or 1)

    self:setSoundSuppressed(true)
    if FocusManager ~= nil and self.topicList ~= nil then
        FocusManager:setFocus(self.topicList)
    end
    if self.topicList ~= nil and self.topicList.setSelectedIndex ~= nil then
        pcall(function() self.topicList:setSelectedIndex(self.currentTopic or 1) end)
    end
    self:setSoundSuppressed(false)
end

function DistributionHelpDialog:onClose()
    DistributionHelpDialog:superClass().onClose(self)
end

-- ---- SmoothList delegate (shared by both lists) ----------------------------
function DistributionHelpDialog:getNumberOfItemsInSection(list, section)
    if list == self.topicList then
        return #TOPICS
    else
        return #self.lines
    end
end

function DistributionHelpDialog:populateCellForItemInSection(list, section, index, cell)
    if list == self.topicList then
        local topic = TOPICS[index]
        local nameCell = cell:getAttribute("topicName")
        if nameCell ~= nil and topic ~= nil then nameCell:setText(topic.title or "?") end
    else
        local row = self.lines[index]
        local lineCell = cell:getAttribute("bodyLine")
        if lineCell ~= nil then
            lineCell:setText(row ~= nil and row.text or "")
            -- emphasise sub-headings without per-row profile swapping
            if lineCell.setTextBold ~= nil then
                pcall(function() lineCell:setTextBold(row ~= nil and row.head == true) end)
            end
        end
    end
end

function DistributionHelpDialog:onListSelectionChanged(list, section, index)
    if list == self.topicList and index ~= nil and index > 0 then
        if index ~= self.currentTopic then
            self:selectTopic(index)
        end
    end
end

function DistributionHelpDialog:onClickTopic(element)
    -- selection change drives the content; nothing extra needed here
end

function DistributionHelpDialog:onClickBodyRow(element)
    -- content rows are read-only
end

-- onClickBack (Close) is inherited from DialogElement
