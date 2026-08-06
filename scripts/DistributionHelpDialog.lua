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
Distribution Redux replaces the base game's distribution system with a demand-driven one, and extends it to buildings the base game leaves out: animal husbandry, silos and storage, and your own markets. Once an in-game hour it works out what every consumer actually needs and delivers only that. Surplus can be sold, stored, or moved elsewhere afterwards. No extra placeables are needed. It works with all default buildings, and with building mods that follow the standard GIANTS schema for their building type.

## Two keys
Backslash key: open the Distribution Redux menu - a full-screen window with a tab for every kind of building, plus this guide and the settings.
Left-bracket key: while on foot, look at a building's loading or unloading point to open the menu straight to that building's page. The prompt only appears when you are looking at one of your own buildings that is part of the network.
Both keys can be rebound under Options - Controls.

## The idea
Open the menu, pick the building you care about, and set each product to Hold, Distribute, Sell, and so on. That is the whole loop - everything else is detail.

## If something is not moving
Three things explain most "why is nothing happening" moments, and each has its own section later in this guide:
A source must be set to a Distribute mode before anything is delivered from it.
Product that has just arrived at a building waits one hour before it can be sold or sent to a market, so that consumers get first refusal (see How It Works).
Move To starts with every destination blocked on purpose, so nothing moves until you activate a destination (see Output Modes).]]
    },
    {
        title = "The Menu",
        body = [[
The backslash key opens the consolidated menu. Down the left side are tabs.

## Tabs
Productions - factories and production points.
Silos - bulk silos and pallet / bale storage sheds, plus manure and slurry pits.
Animal Husbandry - barns, coops, pens and beehives.
Markets - the kiosks and markets you have placed on the map.
Overview - detailed figures for every building and every product in one table.
User Guide - this guide.
Settings - the global options.

Each building tab is a two-pane page: your buildings listed on the left, and the selected building's incoming products, production lines and outgoing products on the right. Exactly which of those three lists appear depends on what the building does.

## Timescale
Every building tab, and the Overview tab, has a Timescale selector at the top offering Hour, Month and Year. It rescopes the flow figures on that page - what was received, consumed, produced, distributed and sold in that window.

A Distribution Redux "month" is 24 hourly passes, so Month means roughly the last in-game day regardless of how many real days you have set per period. Held is never rescoped: it is a stock, not a flow, so it always shows what is in the building right now.

Year data builds up over time. There was no year-scale record before this feature existed, so on an older save the Year column starts empty and fills as each in-game month completes.

## Hidden tabs
The Silos, Animal Husbandry and Markets tabs only appear when that group is switched on in Settings. Switch a group off and its buildings leave the distribution network entirely and its tab disappears. Turn the group back on to get both back.]]
    },
    {
        title = "Building Pages",
        body = [[
The Productions, Silos, Markets and Animal Husbandry tabs share one layout: pick a building on the left, then configure its products on the right. Column sets differ slightly by building type, because not every building consumes or produces.

## Incoming products
PRODUCT - the name and icon.
HELD (CAP) - how much of it is in the building now, with what it can hold in brackets.
RECEIVED - how much Distribution Redux delivered in the selected timescale.
CONSUMED - how much the building used up. Productions and Animal Husbandry only.
DISTRIBUTION - whether the incoming link is Idle, Active, or Blocked.

## Production lines (Productions only)
PRODUCTION LINES - the product the line makes, with its inputs in brackets.
STATUS - Running, Idle (switched on but missing inputs), or Off.
TARGET /mo - how much that line is expected to produce per month.

## Outgoing products
PRODUCT - the name and icon.
HELD (CAP) - how much of this output is in the building now, with capacity in brackets.
PRODUCED - how much was produced in the selected timescale. Productions and Animal Husbandry only.
DISTRIBUTED - everything that left: distributed, stored, moved and sold combined, with the sale value in brackets when any of it sold.
OUTPUT MODE - the mode this output is currently set to.
STATUS - Active - Running, Active - Idle, or Blocked.

## How Held is written
Held always reads the same way across every tab: the amount, then what it can hold in brackets, then any pallets standing on the building's pad.

  473 L (55 kL) + 3 kL (3p)

That is 473 litres in the building's internal store, out of a 55,000 litre capacity, plus three pallets on the pad carrying 3,000 litres between them. A building with no pallets simply omits the last part. Where capacity cannot be determined, the bracket is left off rather than guessed at.

Volumes switch unit at 1,000 litres. Up to 999 L they read in litres; from 1,000 L up they read in kilolitres with any extraneous zeros dropped, so 1,001 L shows as 1.001 kL, 123,123 L as 123.123 kL, and 600,000 L simply as 600 kL. Three decimals is exactly one litre, so nothing is lost in the change of unit.

## Changing settings
To turn a production line on or off, select the line and press Toggle Line.
To change what happens to an output, select it and press Cycle Output.
Advanced opens the per-product routing controls (see Advanced Inputs and Outputs).
Sell Timing appears for an output in a selling mode.

Changing a production output or toggling a line here is the same setting as the vanilla production screen's output toggle, so either place updates the other - and the vanilla screen shows the mod's mode names too.]]
    },
    {
        title = "Output Modes",
        body = [[
## Which modes each building type offers
Productions - Distribute, Store, Hold Pallets, Hold Internal, Sell, Market Supply.
Silos and storage - Distribute, Move To, Hold, Sell, Market Supply.
Animal Husbandry - Distribute, Store, Hold Pallets, Hold Internal, Sell, Market Supply.
Markets - Sell or Hold only.

Not every mode is offered all the time. If a mode has no possible end point it is hidden rather than shown as a dead end: with no market placed, or no market that accepts the product, Market Supply does not appear in the list. If a mode you were using loses its last end point, that output is quietly returned to Hold on the next hourly pass.

## The modes
Distribute - feed nearby productions and animals that need this product, nearest source first, up to what their recipes call for. Surplus stays put.
Store - move the output into any storage building that accepts it, nearest first, spilling to the next when one fills. Productions and Animal Husbandry.
Move To - move product from one storage building to another that accepts it. Storage buildings only. See the warning below.
Hold Internal - keep the output as bulk inside the building; no pallets spawn on their own and you spawn them yourself on demand (see Pallet Spawning).
Hold Pallets - keep the output where it is, as pallets, and let it accumulate.
Sell - sell the product, either immediately or at the best price (see Sell Timing).
Market Supply - transfer the output to a market or kiosk you have placed, where it sells at a premium.

## Combined modes
Distribute + Sell - feed all demand first, then sell what is left.
Distribute + Store - feed demand first, then move the surplus into your storage instead of selling it. Productions and Animal Husbandry only.
Distribute + Move To - feed demand first, then move the surplus to your chosen storage. Storage buildings only.
Distribute + Market Supply - feed demand first, then transfer the surplus to your market or kiosk.

In every combined mode the first half genuinely happens first. Nothing is sold, stored or shipped to a market until consumers have been offered it.

## Move To starts fully blocked - this is deliberate
Move To is the one mode whose destinations all start blocked. Without that, one store would cascade into the next and product could end up looping between two silos forever, paying a distribution charge every hour to achieve nothing.

So when you set an output to Move To, nothing moves until you open Advanced Outputs and activate the destinations you want. If a destination would complete a loop - A to B where B already moves to A, or any longer ring - it is shown as "Active - Invalid" in red and cannot be activated.

Move To depends on Advanced routing. If you switch Advanced routing off in Settings, Move To disappears from the mode list and any output already using it is returned to Hold on the next hourly pass.]]
    },
    {
        title = "Advanced Inputs and Outputs",
        body = [[
Advanced routing lets you control every individual input and output of every building. It is switched on by default and can be turned off in Settings.

## Advanced Inputs
Select any incoming product and press Advanced.
Block / Unblock - stop this building from ever receiving that product.
Max In - the most of that product the building may hold. This matters for pooled storage, where several products share one tank. A pool is first come, first served: by default every product may use all of it, exactly as the base game behaves. That means a busy product can fill a silo and leave little room for the others - so set Max In on that product to cap it and hold space back for the rest. Caps are independent and do not have to add up to 100 percent; anything you leave alone stays unlimited.
Target - a fill target for that product. Instead of delivering only what the next cycle needs, the network works towards this level and then holds it - in effect an input reserve.

## Advanced Outputs
Select the outgoing product you want to adjust and press Advanced.
Block / Unblock - never send this output to that destination.
Prioritise - rank the demands and storage options for this output. This overrides the default nearest-first-then-spill behaviour.
Reserve - keep this many litres in the building at all times. Nothing - distributing, selling, storing, moving or market supply - may take the product below this figure.
Block All / Activate All - flip every destination at once. Activate All still refuses any destination that would create a Move To loop, and tells you how many it skipped.

## Two things to know before switching Advanced routing off
Move To stops being available completely, and any output using it is returned to Hold on the next hourly pass.
Every advanced setting you have made is erased, not merely ignored - all blocks, priorities, reserves, Max In values and targets. Turning Advanced routing back on later gives you a clean slate, so you will need to set it all up again.]]
    },
    {
        title = "Overview Tab",
        body = [[
The Overview tab puts the entire network in one table: every enrolled building, and every product going into or out of it. It is the place to look when you want to know what is actually happening rather than what a single building is set to.

Each product is tagged (In), (Out) or (In/Out) so you can see at a glance which side of the building it sits on. Silos and sheds are In/Out for everything, since they both receive and supply.

## The four selectors
Filter by - Nothing (show all), Building, Product, or End product (full chain).
Show - picks which building or product the filter applies to.
Timescale - Hour, Month or Year, as on the building tabs.
Grouping - Off shows one row per building; On combines buildings of the same type into a single summed row, labelled for example "Bakery x2".

End product (full chain) is the most useful of these. Pick a finished product such as cake and the table shows every building and every intermediate product that feeds it, ordered from the finished item back down the chain. It is the quickest way to find the bottleneck or the oversupply in a production line.

## The columns
RECEIVED - delivered to this building by Distribution Redux.
LOADED - put into this building by anything that is NOT Distribution Redux: you with a trailer, a bale, an AI helper, another mod.
CONSUMED (EXP.) - used up, with the expected figure in brackets.
UNLOADED - taken out of this building by anything that is not Distribution Redux, including a pallet you drive away.
HELD (CAP) - what is in the building right now, with capacity. Never rescoped by Timescale.
PRODUCED (EXP.) - made by this building, with the expected figure in brackets.
DISTRIBUTED - delivered out to consumers.
STORED/MOVED - sent to storage, or moved to another store.
SOLD - sold, whether directly or through a market.
DISTR. COST - what the haulage for this building's deliveries cost. Charged to the sending building only, so the column adds up to the money actually spent rather than counting each delivery twice.

## The expected figures and their colours
CONSUMED and PRODUCED carry the expected amount in brackets, worked out from the recipes of the production lines that are switched on. The figure is coloured green when it is at or very near target, orange when it is slightly short, and red when it is well short. Only productions have a recipe, so animal husbandry and silo rows show a plain figure with no target rather than an invented one.

A red PRODUCED figure is the fastest way to spot a starved line. Before assuming a fault, check the note on shared throughput in How It Works - a building running several lines at once may be behaving perfectly.]]
    },
    {
        title = "Pallet Spawning",
        body = [[
Many outputs are delivered on pallets - boards, planks, vegetables in crates, eggs, wool and so on. Distribution Redux lets you keep those outputs as bulk and spawn pallets by hand only when you want them, instead of the building dropping them automatically.

## Spawning by hand
Set the output to Hold Internal. Once it holds at least one full pallet's worth, a Spawn Pallets button appears, both on the Productions tab and on the base-game production screen. Press it to open the spawn window.
Type - the pallet type. If the output supports only one it is shown for reference; if it supports several, use the arrows to choose.
Quantity - how many to spawn. The arrows step by one, the -10 / +10 buttons jump in tens, and the total is capped by the stock you hold.
Spawn drops that many filled pallets at the building's pallet point and removes the matching stock. Cancel closes without spawning.

The button only appears for an output on Hold Internal holding at least one full pallet's worth - below that there is nothing to spawn. The building must also have a pallet spawn point in its model, which most palletising buildings do. In multiplayer the host performs the spawn, so the pallets appear for everybody.

## Whole pallets from animal pens
By default, animal pens behave like productions: they accumulate their output internally and release one whole pallet at a time, rather than dropping an empty pallet immediately and trickling into it for hours. This is the "Whole pallets from pens" setting, and it is on by default.

While a pen is filling towards its next pallet, that stock is not invisible. A consumer that needs the product can still draw on it - the pen releases what is needed on demand. What does wait for a full pallet is selling, storing and market supply, since those need a physical pallet to move.

Turn the setting off to return to vanilla behaviour, where a part-filled pallet appears straight away and fills gradually.

## Which pallets belong to a building
A building's stock lives in two places: bulk litres in its internal store, and whole pallets standing on its pallet pad. The Held column shows both (see Building Pages).

The pad is the marked area the building spawns pallets onto, and it is only as big as the rows you can see. A bakery row holds five pallets end to end, roughly seven metres. Larger factories have longer rows, and some have several rows side by side.

A pallet on one of those rows belongs to that building, full stop. Nudging one along the row does not release it, and a neighbouring building will never claim it even if its own doors are closer - two buildings side by side cannot steal each other's pallets.

To take a pallet out of the network, move it clear of the rows: into a pallet store, onto a trailer, or a couple of metres off to one side. Once off the pad it stops counting towards that building's held stock and the mod leaves it alone. Drive it away and it shows up under UNLOADED on the Overview tab, so hand-moved product is still accounted for.

Buildings without a proper pallet pad in their model - some modded spawners, and a few beehives - fall back to a simple nearest-building rule instead.]]
    },
    {
        title = "How It Works",
        body = [[
## The hourly pass
Once an in-game hour, on the host, the mod runs a single tidy pass.

1. Feed and water
It looks at every active production line and every enrolled animal pen, works out what they need, and pulls those inputs from buildings set to a Distribute mode - nearest source first. Anything needing water is topped up at the same time. It sends a buffer, not a flood: a consumer is filled to roughly the consumer buffer setting (2 hours of feedstock by default), so one factory cannot vacuum up the whole farm.

2. Store the surplus
Distribute + Store outputs push their leftovers into storage, and Store pushes everything in - nearest store first, spilling to the next. Move To outputs go to the destinations you activated. This happens after feeding, so storing never takes stock a factory still needed.

3. Supply your markets
Market Supply and Distribute + Market Supply outputs are transferred to the markets and kiosks you have placed, again only after feeding.

4. Sell the surplus
Sell and Distribute + Sell outputs are sold last, so a sale never beats a hungry consumer to the stock. With best-price timing, a sale waits for the price peak.

## Nothing is sold before it has been offered
Product that arrives at a building part-way through a pass is not sold, stored to a market, or shipped out in that same pass. It waits until the next one, so that consumers get the chance to ask for it first.

This is why a chain like producer to Store to a silo set to Distribute + Sell to a consumer works at all. Without the rule, product would arrive at the silo in step 2 and be sold in step 4 of the very same pass, having never been offered to anyone. The cost is that freshly arrived product takes one extra in-game hour before it can leave the network.

## Some buildings share one throughput budget
Production points come in two kinds, and it changes what "expected" means.
Most run every active line at its own full rate. A grain mill making wheat flour and barley flour makes both at full speed, and its consumption is the sum of the two.
Others share a single throughput budget across their active lines. A dairy running bottled milk and butter together does not consume the sum of both rates - it splits one budget between them, so each runs at about half speed.

Distribution Redux detects which kind a building is and sizes both its deliveries and its Overview expectation to match. This is worth knowing because a shared-throughput building running several lines looks, at a glance, like it is only half fed. It is not - it is working exactly as the base game intends.

## Seasonal and periodic products
Sell Timing - for any output in a selling mode you can choose to sell immediately or to wait for the best price. Waiting means the product accumulates in the building until the peak arrives, so make sure there is room for it.
Seasonal harvest reserve - switched OFF by default. When you turn it on, an output that is an annual harvest crop will keep roughly a year's worth back to feed your own productions and sell only the surplus. Grass and other crops that regrow through the year keep three months instead. Until the mod has seen a crop harvested it does not know when the next harvest is due, so it falls back to the Reserve months setting.
Water - water is supplied automatically to any building that needs it, from the nearest water source, while Auto-Water is on.

## Bunker silos
Bunker silos take part as a source only, and only for finished silage in an uncovered bunker. They cannot be a Move To destination, because product cannot be tipped back into a bunker by the distribution system.]]
    },
    {
        title = "Costs and Participation",
        body = [[
## Distribution costs
Moving goods is not free by default. The mod charges a small per-hour cost for each active delivery link - feeding, storing offsite and watering all count - so that teleporting everything everywhere is not an automatic win. The charge appears under your farm's maintenance and upkeep.

How it is calculated: the cost of one link for one hour is the cost rate multiplied by the distance in whole increments of the cost distance. The defaults are a rate of 10 and a distance of 50 m. A delivery within 50 m costs the flat rate; one at 150 m costs three times the rate. Water is billed the same way. Costs are totalled per farm each hour.

You can lower the rate, widen the distance, or switch the whole thing off in Settings. Switching it off makes watering free too.

Per building, the Overview tab's DISTR. COST column shows exactly what each building's deliveries cost you.

## What takes part
Three settings decide which buildings join the network.

Scope
Range - every eligible building takes part, across the whole farm. The most hands-off option.
Proximity - eligible buildings take part, but a source only reaches consumers within the proximity radius (50 m by default).

Animal Husbandry (on / off)
Includes or excludes barns, coops, pens and beehives. Off removes them entirely - they are neither fed nor is their output distributed or sold - and hides their tab.

Silos and Pallet Storage (on / off)
Includes or excludes bulk silos, pallet and bale sheds, and manure and slurry pits. Off removes them - silos stop feeding productions and sheds neither receive nor release pallets - and hides their tab.

Markets and Kiosks (on / off)
Includes or excludes your markets and kiosks. Off means they cannot be supplied, and hides their tab.

Productions
Productions always take part, exactly as in the base game. There is no switch to exclude them.]]
    },
    {
        title = "Settings",
        body = [[
Global settings live on the Settings tab. They are saved with your profile and synced in multiplayer by the host. Per-building choices always override these globals for that building.

## The options
Listed in the order they appear on the tab.
Scope - Range (whole farm) or Proximity (within a radius).
Animal Husbandry - include or exclude barns, coops, pens and beehives.
Silos & Pallet Storage - include or exclude bulk silos, pallet and bale sheds, and manure and slurry pits.
Markets & Kiosks - include or exclude your markets and kiosks.
Advanced routing - master switch for Advanced Inputs and Advanced Outputs. Off also removes Move To and erases every advanced setting (see Advanced Inputs and Outputs).
Proximity radius - how far a source reaches in Proximity scope. Default 50 m.
Consumer buffer - hours of feedstock topped up at each consumer per cycle. Default 2.
Selling - master on / off for all selling. Off means nothing is ever sold, whatever individual outputs are set to.
Auto-Water - automatically supply water to buildings that consume it.
Distribution cost - whether haulage is charged at all.
Cost rate - the base charge per link per hour. Default 10.
Cost distance - the distance increment the rate is multiplied by. Default 50 m.
Seasonal harvest reserve - keep enough feedstock to last until the next harvest, selling only the surplus. Off by default.
Reserve months (until learned) - how many months to hold back before the mod has learned a crop's harvest window. Default 13.
Sell at best price - master on / off for best-price selling. Off means everything sells immediately.
Default sell timing - what a new output uses when you have not set it: wait for the peak, or sell immediately.
Whole pallets from pens - animal pens accumulate internally and release full pallets, like productions. On by default; off returns to the vanilla trickle-fill.
Debug logging - write detailed activity to log.txt. Leave off for a quieter log.]]
    },
    {
        title = "Support",
        body = [[
## Troubleshooting
A building is not showing up. Check Scope and the group toggles. Proximity only reaches within the radius, and a building whose group is switched off is removed from the network and its tab hidden.

Nothing is being delivered. Make sure the source is set to a Distribute mode rather than Hold, the consumer's production line is switched on, and the two are within reach for the current scope.

A Move To output is not moving anything. Move To starts with every destination blocked. Open Advanced Outputs and activate the destination you want. If a destination shows "Active - Invalid" in red, activating it would create a loop.

Something arrived but did not sell this hour. That is intended. Product that has just arrived waits one pass so consumers get first refusal.

A production shows a red expected figure but looks fine. If it runs several lines at once it may share one throughput budget between them, in which case it is working correctly. See How It Works.

An animal pen is holding its eggs or wool. With "Whole pallets from pens" on, a pen accumulates until it has a full pallet before releasing one. Consumers can still draw on the stock while it fills; selling and storing wait for the pallet.

A factory is not getting water. Water is supplied automatically while Auto-Water is on; if a water-input plant looks starved, confirm the setting.

No prompt at a building. The left-bracket prompt only shows for buildings that are part of the network. If you excluded that group in Settings, the prompt is gone by design.

Do not run this alongside other distribution-overhaul mods - they hook the same system and will fight. The mod works with base-game buildings and with modded buildings that follow the standard GIANTS schema; some modded buildings may behave differently.

## Guides and overviews
Overviews and guides are on my YouTube channel, @AussieSimmer.

## Bug reporting
Bugs, feature requests and mod compatibility requests can be raised as a ticket on my GitHub repository:
https://github.com/Bones50/FS25-Distribution-Redux]]
    },
    {
        title = "Changelog",
        body = [[
## v1.1.0.0
1. Numerous bug fixes and improvements (see GitHub for full details).
2. Compatibility added for many mods, and the code strengthened to improve mod compatibility overall (see GitHub for full details).
3. Added the Overview tab - every building and every product in one table, with supply-chain filtering.
4. Added Advanced Input and Output management (block, prioritise, reserve stock, fill target, max in).
5. Added the Move To output mode, which combined with the above lets you move and sort product between silos, pallet warehouses and other stores.
6. Added manual load and unload tracking, so product you move by hand appears on the Overview tab instead of vanishing/magically appearing.

## v1.0.0.2
1. Renaming buildings - every building in the distribution network can now be given a custom name from the base-game construction menu. The game only allows this on some buildings by default; Distribution Redux enables it for all of its buildings (silos, sheds, pits and markets included). The mod then uses your name everywhere in this menu, with the original building name shown underneath it as a reference, so a farm with eight identical greenhouses is finally readable.
2. Manure Heap / Slurry Pit product fix - each was listing the other's product as an output. The Manure Heap now shows only Manure, and the Slurry Pit only Slurry.
3. Manure Heap / Slurry Pit incoming fix - neither showed an incoming product. They now list what actually flows into them (manure and slurry respectively).

## v1.0.0.1
1. UI improvements and a consistency pass, including scroll bars, repositioned tables, and the value of products sold added to the sold column.
2. Added Markets and Kiosks to the distribution system - all buildings now have a Market Supply option to route their output to a market you have placed. Items sold through your market get a 20% price bonus, although selling in bulk reduces the price you get, just like the base game.
3. Sell at Best Price fix - with no pricing history the system sold earlier than expected. It now falls back to the in-game price graph until it has gathered enough of its own data.
4. Added Hold Internal mode and manual pallet spawning - palletisable outputs can be kept as bulk stock instead of auto-spawning pallets, then spawned by hand through a spawn window where you pick the pallet type and quantity. Available from both the Productions tab and the base-game production screen.

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
Pre-release.]]
    },
}

DistributionHelpDialog.TOPICS = TOPICS

-- ---- guide source ----------------------------------------------------------
-- The TOPICS table above is the ONE AND ONLY source for the in-game guide. The mod does NOT read
-- helpGuide.txt, and must not be made to: the runtime read DESTROYED it.
--
-- What happened: reload() opened each candidate path with io.open(path, "r") and, in the GIANTS Lua
-- sandbox, that TRUNCATED the file to 0 bytes instead of merely reading it. Because reload() walked both
-- candidate paths in a single call, the mod-folder copy and the modSettings copy were emptied in the same
-- instant -- which is exactly what was observed (identical mtimes to the nanosecond, while an unrelated
-- canary file placed beside each survived untouched). The guide never came up blank in game only because
-- the TOPICS fallback below caught every one of those failures.
--
-- helpGuide.txt still lives in the mod folder as the AUTHORING copy, in the same
-- "[Tab Name] / # Heading / body text / ; comment" format, and parseGuide() below still understands it.
-- The workflow is now deliberate rather than automatic: edit the text file, then have the TOPICS table
-- regenerated from it. Nothing at runtime touches the filesystem, so the file cannot be eaten again.
DistributionHelpDialog.GUIDE_FILE = "helpGuide.txt"       -- authoring copy only; never opened at runtime

local function parseGuide(text)
    local topics, cur = {}, nil
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        local tab = line:match("^%s*%[(.+)%]%s*$")
        if tab ~= nil then
            cur = { title = tab, lines = {} }
            topics[#topics + 1] = cur
        elseif line:match("^%s*;") then                       -- comment
            -- skipped
        elseif cur ~= nil then
            local head = line:match("^%s*#+%s*(.+)$")
            -- re-emit headings in the "## " form buildLines already understands, so there is exactly one
            -- rendering path whether the content came from the file or the built-in table
            cur.lines[#cur.lines + 1] = head ~= nil and ("## " .. head) or line
        end
    end
    local out = {}
    for _, t in ipairs(topics) do
        -- trim leading/trailing blank lines so file spacing does not shift the pane
        local l, first, last = t.lines, 1, #t.lines
        while first <= last and l[first]:match("^%s*$") do first = first + 1 end
        while last >= first and l[last]:match("^%s*$") do last = last - 1 end
        if last >= first then
            local body = {}
            for i = first, last do body[#body + 1] = l[i] end
            out[#out + 1] = { title = t.title, body = table.concat(body, "\n") }
        end
    end
    return out
end
DistributionHelpDialog.parseGuide = parseGuide

-- No file reading. Kept as a function because DistributionHelpPage:onFrameOpen calls it on every tab
-- open (via pcall) and the Help page is happy either way -- it simply reasserts the built-in TOPICS now.
-- Returns false, meaning "the built-in text is what you are seeing", which is always true.
-- DO NOT reintroduce a filesystem read here (see the note above the TOPICS table).
function DistributionHelpDialog.reload()
    DistributionHelpDialog.TOPICS = TOPICS
    DistributionHelpDialog.loadedFrom = nil
    return false
end

DistributionHelpDialog.reload()

-- ---- word wrap -------------------------------------------------------------

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
