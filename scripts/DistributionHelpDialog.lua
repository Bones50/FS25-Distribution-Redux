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
Distribution Redux replaces the base-game hourly distribution with a demand-driven, proximity-aware system you steer building by building. Each in-game hour it decides what gets fed to your factories and animals, what gets watered, what gets sold, and what gets stored - all on your existing base-game buildings, with no extra placeables.

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
User Guide - this guide.
Settings - the global options.

## Hidden tabs
The Silos tab and the Animal Husbandry tab only appear when that group is switched on in Settings. If you have excluded silos and pallet storage, or excluded animal husbandry, the matching tab is hidden - turn the group back on to see it again.

Each building tab is a two-pane page: your buildings listed on the left, and the selected building's products on the right.]]
    },
    {
        title = "Building Pages",
        body = [[
The Productions, Silos and Animal Husbandry tabs share one layout: pick a building on the left, configure its products on the right - one row per product the building holds or handles.

## Columns
Product - the name and icon.
Held / Stock - how much is in the building now.
Distr. / cyc - litres distributed in the last in-game hour.
Sold / cyc - litres sold last hour.
Stored / cyc - litres pushed into storage last hour.
Mode - the product's current output mode (and, for selling, its sell timing).

## Setting a mode
Cycle the highlighted product to step it through the available modes, or cycle the whole building at once. Bulk stores (silo, shed, pit) step through Distribute, Hold, Distribute + Sell, Sell. Productions and animal barns also reach Distribute + Store and Store, because they make a surplus worth stashing elsewhere.

Changing a production output here is the same setting as the vanilla production screen's output toggle, so either place updates the other - and the vanilla screen shows the mod's mode names too.]]
    },
    {
        title = "Output Modes",
        body = [[
A mode tells the mod what to do with a product, or a production output, each hour. The names read the same on the production screen and in the mod's pages.

## Hold
Leave it where it is. The mod will not move or sell it. (This was called "Stored" in earlier versions.) Use it for anything you want to manage by hand.

## Distribute
Feed nearby productions and animals that need this product, nearest source first, up to what their recipes call for. Surplus stays put.

## Sell
Sell it each hour - immediately, or once it reaches its best price (see Sell Timing).

## Distribute + Sell
Feed demand first, then sell whatever is left over.

## Distribute + Store
Feed demand first, then move the surplus into your other storage (silos and sheds) instead of selling it. Productions and barns only.

## Store
Do not distribute at all; move the whole product straight into your other storage. Use it to funnel everything to one central store. Productions and barns only. (This was called "Store Offsite" in earlier versions.)

## Where storage goes
For Distribute + Store and Store, the surplus fills the nearest suitable storage first, then overflows to the next, until it is placed or every store in reach is full. A plain silo, shed or pit is itself storage, so it cannot cascade into another store - that is why those two modes are productions and barns only.]]
    },
    {
        title = "Sell Timing",
        body = [[
Anything set to Sell or Distribute + Sell can either sell straight away or wait for a good price.

## Immediate
Sell the surplus each hour at whatever the current price is. Simple and steady.

## Best price
Hold the surplus back and only sell when the price is at, or near, the top of its cycle. The mod reads the season's price curve for each crop and waits for the peak, so you earn more per litre at the cost of selling less often.

Set the timing per product on the building's page, or set the default for everything in Settings. Best price needs the seasonal price information the game provides; where that is unavailable, the product falls back to immediate.]]
    },
    {
        title = "The Hourly Pass",
        body = [[
Once an in-game hour, on the host, the mod runs a single tidy pass in three steps.

## 1. Feed and water
It looks at every active production line and enrolled animal pen, works out what they need, and pulls those inputs from buildings set to a Distribute mode - nearest source first. Anything needing water is topped up at the same time. It sends a buffer, not a flood: a consumer is topped up to about the buffer hours of feedstock (default 2 hours), so one factory cannot vacuum up the whole farm.

## 2. Store the surplus
Distribute + Store outputs push their leftover into storage, and Store pushes everything in - nearest store first, overflowing to the next. This happens after feeding, so storing never grabs stock a factory still needed.

## 3. Sell the surplus
Sell and Distribute + Sell outputs are sold, also only after feeding - a sale never beats a hungry consumer to the stock. With Best price timing a sale waits for the price peak, and an optional seasonal reserve can hold back enough feedstock to last until the next harvest.]]
    },
    {
        title = "Feeding and Water",
        body = [[
## Feeding animals
Animal husbandry is handled alongside productions. Enrolled barns are auto-fed the inputs their animals consume - food, optionally straw bedding, and water - from sources within reach, the same demand-capped, nearest-first way productions are fed. Straw bedding can be turned off separately.

## Water supply
Factories that take water as an input, and pastures that need water but have no automatic supply, are topped up automatically each hour from an effectively unlimited ambient supply - so a water-hungry plant or thirsty pasture will not stall just because you have not trucked water to it.

It is not free: each watered building is billed for the haul distance to its nearest water source, using the same per-link distribution cost as everything else. A water source is whichever is closer of a building that holds or makes water, or open water - a river, lake or pond. If there is no source in range, water still flows at the flat base rate. Pastures with their own automatic supply are left to the game and never billed. Switch the feature off with the Auto-Water setting.]]
    },
    {
        title = "Distribution Costs",
        body = [[
By default, moving goods is not free - the mod charges a small per-hour distribution cost for each active delivery link (feeding, storing offsite, and watering all count), to stop teleport-everything-everywhere from being a no-brainer. The charge appears under your farm's maintenance and upkeep.

## How it is calculated
The cost for one link each hour is the base times max(1, distance divided by the threshold), with a base of 10 and a threshold of 50 m by default. A delivery within 50 m costs the flat base; one at 150 m costs three times the base. Water is billed the same way. Costs are summed per farm each hour.

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

## Productions
Productions always take part, exactly as in the base game - there is no switch to exclude them.]]
    },
    {
        title = "Pallet & Bale Storage",
        body = [[
Pallet and bale storage sheds work a little differently from bulk silos, because they hold whole objects rather than litres.

## Pre-configuring products
A shed's page lists every pallet and bale your network can actually supply that the shed accepts - your productions' pallet outputs, your animals' eggs, wool and honey, and the baleable crops you have on hand - even if none are in the shed yet. So you can set how each should be handled before the first one arrives. Anything already sitting in the shed always shows too, even if you loaded it by hand.

## Keeping space free (reserve)
When a shed fills up, the mod first tries to move surplus pallets to another of your sheds that has room - most valuable kept, least valuable moved. If there is nowhere to relocate them, it sells off the least valuable pallets to keep a slot free for next cycle's output. A shed with somewhere to relocate to will never sell.]]
    },
    {
        title = "Silo Extensions",
        body = [[
Silo extensions add storage capacity to a silo without being managed separately.

## How they work
Place an extension within the vicinity of a silo of the matching type, and its capacity folds into that primary silo. You configure distribution on the primary silo only - the extension simply adds room. It does not appear as its own building and has no separate modes.

If an extension is not behaving, check that it is close enough to a silo that stores the same product; an extension with no matching silo nearby has nothing to attach to.]]
    },
    {
        title = "Biogas Plants",
        body = [[
Biogas plants are productions, so they take part automatically.

## Selling methane and electricity
A biogas plant that sells methane or feeds electricity to the grid is paid at the game's grid rate, scaled by your economic difficulty setting - so the income matches the difficulty you are playing on.

## Digestate
Digestate the plant produces is recorded as Biogas Plant income on your finances page, rather than being mislabelled, so your books read correctly.]]
    },
    {
        title = "Settings",
        body = [[
Global settings live on the Settings tab. They are saved with your profile and synced in multiplayer by the host. Per-building choices you make on a building's page always override these globals for that building.

## The options
Scope - Range (whole farm) or Proximity (within a radius).
Animal Husbandry - include or exclude barns, coops, beehives and manure / slurry pits.
Silos & Pallet Storage - include or exclude bulk silos and pallet / bale sheds.
Proximity radius - how far a source reaches in Proximity scope.
Consumer buffer - hours of feedstock topped up at each consumer per cycle.
Selling - master on / off for all auto-selling.
Best price - default sell timing: wait for the price peak, or sell immediately.
Auto-Water - automatically supply water to water-input productions and pastures.
Distribution cost / rate / distance - the per-hour transport cost and how it scales.
Seasonal harvest reserve - keep enough feedstock to feed production until the next harvest, selling only the surplus.
Debug logging - write detailed activity to log.txt; turn off for a quieter log.]]
    },
    {
        title = "Multiplayer and Saving",
        body = [[
## Multiplayer
Supported. The distribution pass runs on the host, and any mode or timing change you make is broadcast so it reaches the host and every player. Storage changes flow through the game's normal sync. The per-cycle stats and money notifications shown in the pages are the host's figures, since the host runs the pass.

## Saving
Your per-building, per-product choices are saved with your savegame and restored when you load back in, keyed to each building, so they survive across sessions. You do not need to re-set anything after a reload.

## Reading the per-cycle numbers
The Distr., Sold and Stored per-cycle columns show what happened in the most recently completed in-game hour - a snapshot, not a live ticker. They read zero right after you open a page, until the next hour ticks over.]]
    },
    {
        title = "Troubleshooting",
        body = [[
A building is not showing up? Check Scope and the group toggles - Proximity only reaches within the radius, and a building whose group (Animal Husbandry, or Silos & Pallet Storage) is switched off is removed from the network and its tab hidden.

Nothing is being delivered? Make sure the source is set to a Distribute mode (not Hold), the consumer's line is active, and the two are within reach for the current scope.

A factory is not getting water? Water is supplied automatically when Auto-Water is on; if a water-input plant looks starved, confirm the setting.

No prompt at a building? The left-bracket prompt only shows for buildings that are part of the network. If you excluded that group in Settings, the prompt is gone by design.

Do not run it alongside other distribution-overhaul mods - they hook the same system and will fight. The mod works on base-game buildings; some modded buildings may behave differently.]]
    },
    {
        title = "Quick Reference",
        body = [[
## Keys
Backslash - open the Distribution Redux menu.
Left bracket - look at a building's loading point to open its page directly.

## Modes
Hold - do nothing, keep it in the building.
Distribute - feed nearby demand, nearest first.
Sell - sell each hour (immediately or at best price).
Distribute + Sell - feed demand, sell the rest.
Distribute + Store - feed demand, store the rest (productions and barns).
Store - store all of it, no distributing (productions and barns).

## Sell timing
Immediate - sell at the current price.
Best price - wait for the season's price peak.

## Each hour
Feed active productions and animals (a buffer, not a flood, nearest first) and top up water, then store the Store and Distribute + Store outputs (nearest first, overflow to next), then sell the surplus (now, or at best price), then charge a small per-link distribution cost.]]
    },
    {
        title = "Changelog",
        body = [[
## v1.0.0.1
1. Added the ability to specify whether goods should sell immediately or once they hit best price.
2. Completely rebuilt UI that breaks out distribution types and consolidates the settings and help guide into the menu.
3. Fixes to silo extensions so they work in a consistent manner. An extension must now be placed within the vicinity of a matching silo type; all distribution is managed in the primary silo and the extension simply adds storage to it.
4. Pallet and bale sheds now display all active pallets in the network so they can be pre-configured before items arrive. Added a reserve function that sells pallets (least valuable first) to keep space free for the next cycle - bypassed if another pallet shed has space, in which case pallets are moved there instead.
5. Pallet shed interaction fixed: look at the loading-point icon in-game to open that building's distribution page directly.
6. Fixed a small amount of output being left in the source after distribution (a timing issue).
7. Biogas plant fixed: methane and electrical charge sales now take game difficulty into account, and digestate now properly registers as Biogas Plant income on the finance sheet.
8. Settings reworked to be more granular: you can now include or exclude silos / pallet sheds, and include or exclude animal husbandry buildings. Productions always register and participate in distribution, just like the base game.
9. Change in mode titles: Hold now holds items in the building (used to be "Stored"); Store moves items offsite when storage is available.

## v1.0.0.0
Initial Release.]]
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
