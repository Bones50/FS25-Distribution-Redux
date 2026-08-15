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
-- MARKERS IN A TOPIC BODY (the "wire" form -- see parseGuide for the authoring
-- form used in helpGuide.txt, which is one "#" shallower at each level):
--     "## Heading"    main heading   (bold, largest)
--     "### Heading"   sub-heading    (bold, between heading and body)
--     "- Item"        list item      (bulleted, wrapped lines hang under the text)
--     anything else   body text
--     blank line      spacer
-- Never write two consecutive close-brackets in a body: it would end the [[ ]]
-- string early. regen (see below) refuses to write a topic containing them.
--
-- TOPICS IS GENERATED FROM helpGuide.txt and is what players actually see -- the
-- mod does NOT read that file at runtime (a startup read once truncated it to
-- zero bytes; never re-add one). Edit the txt, then regenerate this table.
-- ============================================================================

DistributionHelpDialog = {}
local Dlg_mt = Class(DistributionHelpDialog, MessageDialog)

local WRAP_CHARS = 70     -- character-based word wrap width for the content pane

-- ---- guide content ---------------------------------------------------------
-- Each topic: { title = <string>, body = <text> }. Markers as documented in the
-- file header above. GENERATED FROM helpGuide.txt -- edit there, not here, or
-- the next regeneration will overwrite whatever was hand-written.
local TOPICS = {
    {
        title = "Getting Started",
        body = [[
Distribution Redux completely replaces the base game's distribution system. No extra placeables are needed. It works with all default buildings, and with building mods that follow the standard GIANTS schema for their building type. This is very complicated mod and it can be easy to inadvertently create issues/blockages. Please review the entire help guide prior to use.

## Accessing the UI
Backslash key: open the Distribution Redux menu - a full-screen window with a tab for every kind of building, plus this guide and the settings.
Left-bracket key: while on foot, look at a building's loading or unloading point to open the menu straight to that building's page. The prompt only appears when you are looking at one of your own buildings that is part of the network.
Both keys can be rebound under Options - Controls.

## The Idea
Open the menu, pick the building you care about, and set each product to Hold, Distribute, Sell, and so on. That is the whole loop - everything else is detail.

## What it does differently to base game
- Allows any building that stores, produces, feeds or sells to participate in the distribution.
- Will deliver only what the demand needs rather than trying to fill to capacity
- Charges for distribution based on distance
- Allows you to Sell Immediately or wait until best price is reached
- Allows a seasonal reserve to be held for seasonal crops to ensure productions can continue, only selling the un-needed portion of the harvest
- Auto-watering will pull water from any storage or the nearest water source (e.g. lake) to supply demand
- Allows you to override the default distribution mechanism to prioritise demands, Block specific Inputs and Outputs, Set Output Reserves, and Set Input demand targets

## What it does each cycle
- Allocate - Build a demand list from every consumer: production inputs, animal food, feeding-robot bunkers, straw, husbandry water. Then match sources to demand nearest-first, honouring per-product blocks, priorities and input caps.
- Move the remainder - Store leftovers in available storage buildings, Move Stock to available markets, then Move stock between storages, honouring per-product blocks, priorities and input caps.
- Charge - Distance-based haulage billing, plus the vanilla per-hour production running costs (which are otherwise lost because DR suppresses the base hourly pass).
- Sell / Market Supply - Sell surplus, sell out of market buffers, then sell direct outputs (e.g. electricity, methane), honouring any seasonal harvest, and sell immediate vs sell at best price rules.
- Account - Record Production and husbandry throughput, calculate manual load/unload deltas, emit the money summary.]]
    },
    {
        title = "The Menu",
        body = [[
The backslash key opens the consolidated menu. Down the left side are tabs.

## Tabs
- Productions - factories and production points.
- Silos - bulk silos and pallet / bale storage sheds, plus manure and slurry pits.
- Animal Husbandry - barns, coops, pens and beehives.
- Markets - the kiosks and markets you have placed on the map.
- Overview - detailed figures for every building and every product in one table.
- User Guide - this guide.
- Settings - the global options.

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
The Productions, Silos, Markets and Animal Husbandry tabs share one layout: pick a building on the left, then configure its products on the right. Tables and Column sets differ slightly by building type, because not every building consumes or produces.

## Table Contents
### Incoming products
- PRODUCT - the name and icon.
- HELD/MAX - how much of it is in the building now, the Max amount that could be stored and the max set amount in Brackets as a percentage.
- FREE STORAGE - How much more of this product the building can hold, taking into account the max set amount (%) and remaining space.
- RECIEVED - how much of the product Distribution Redux delivered to this building in the selected timescale.
- CONSUMED - how much of the product the building used in the selected timescale. Productions and Animal Husbandry only.
- STATUS - Active (Recieving) or Active (Idle), based on activity in the last cycle, or Blocked.

### Production lines (Productions only)
- PRODUCTION LINES - the product the line makes, with its inputs in brackets.
- STATUS - Running, Idle (switched on but missing inputs), or Off.
- TARGET /mo - how much that line is expected to produce per month if all inputs are provided.

### Outgoing products
- PRODUCT - the name and icon.
- HELD (MAX) - how much of this product is in the building now, with capacity in brackets.
- FREE STORAGE - How much more of this product the building can hold
- PRODUCED - how much was produced in the selected timescale. Productions and Animal Husbandry only.
- DISTRIBUTED - everything that left: distributed, stored, moved and sold combined, with the sale value in brackets when any of it sold.
- OUTPUT MODE - the mode this output is currently set to.
- STATUS - Active (Sending) or Active (Idle), based on activity in the last cycle, or Blocked.

## NOTE
- If a building can have both internal storage and pallets, the display will show the internal amount and then the amount stored in Pallets on the buildings pallet spawner
- The Selected timeframe will only show material that has been moved in that timeframe, if you have only just activated the production and are showing Annual, you will only see what's moved since you activated it.
- More details on what is going where is available on the overview tab 
- Volumes switch unit at 1,000 litres. Up to 999 L they read in litres; from 1,000 L up they read in kilolitres with any extraneous zeros dropped, so 1,001 L shows as 1.001 kL, 123,123 L as 123.123 kL, and 600,000 L simply as 600 kL. Three decimals is exactly one litre, so nothing is lost in the change of unit.
- To see if a change has taken effect (ie idle or running), you will need to go through one cycle (1 hour) before the UI column refreshes. If you have a chain of distributions, you may have to cycle through a number of hours until all steps refresh. 

## Changing settings
- To turn a production line on or off, select the line and press Toggle Line.
- To change what happens to an output, select it and press Cycle Output.
- Advanced opens the per-product routing controls (see Advanced Inputs and Outputs).
- Sell Timing appears for an output in a selling mode.

Changing a production output or toggling a production line here is the same setting as the vanilla production screen's output toggle, so either place updates the other - and the vanilla screen shows the mod's mode names too.]]
    },
    {
        title = "Output Modes",
        body = [[
## Which modes each building type offers
- Productions - Distribute, Store, Hold Pallets, Hold Internal, Sell, Market Supply.
- Silos and storage - Distribute, Move To, Hold, Sell, Market Supply.
- Animal Husbandry - Distribute, Store, Hold Pallets, Hold Internal, Sell, Market Supply.
- Markets - Sell or Hold only.

Not every mode is offered all the time. If a mode has no possible end point it is hidden rather than shown as a dead end. E.g. with no market placed, or no market that accepts the product, Market Supply does not appear in the list.

## The modes
- Distribute - feed nearby productions and animals that need this product, nearest source first, up to what their recipes call for. Surplus stays put.
- Store - move the output into any storage building that accepts it, nearest first, spilling to the next when one fills. Productions and Animal Husbandry.
- Move To - move product from one storage building to another that accepts it. Storage buildings only. See the warning below.
- Hold Internal - keep the output as bulk inside the building; no pallets spawn on their own and you spawn them yourself on demand (see Pallet Spawning).
- Hold Pallets - keep the output where it is, as pallets, and let it accumulate.
- Sell - sell the product, either immediately or at the best price (see Sell Timing).
- Market Supply - transfer the output to a market or kiosk you have placed, where it sells at a premium.

## Combined modes
- Distribute + Sell - feed all demand first, then sell what is left.
- Distribute + Store - feed demand first, then move the surplus into your storage instead of selling it. Productions and Animal Husbandry only.
- Distribute + Move To - feed demand first, then move the surplus to your chosen storage. Storage buildings only.
- Distribute + Market Supply - feed demand first, then transfer the surplus to your market or kiosk.

In every combined mode the first half genuinely happens first. Nothing is sold, stored or shipped to a market until consumers have been offered it.
Move To is only offered if advanced routing is activated (See Advanced Routing).]]
    },
    {
        title = "Advanced Routing & Rules",
        body = [[
## Advanced Routing
Advanced routing lets you control every individual input and output of every building. It is switched on by default and can be turned off in Settings.

### Advanced Inputs
- Select any incoming product and press Advanced Inputs.
- Block / Allow - stop this building from ever receiving that product.
- Block All / Allow All - flip every input at once.
- Max In - the most of that product the building may hold. This matters for pooled storage, where several products share one tank. A pool is first come, first served: by default every product may use all of it, exactly as the base game behaves. That means a busy product can fill a silo and leave little room for the others - so set Max In on that product to cap it and hold space back for the rest. Caps are independent and do not have to add up to 100 percent; anything you leave alone stays unlimited.
- Target - a fill target for that product. Instead of delivering only what the next cycle needs, the network works towards this level and then holds it - in effect an input reserve.

### Advanced Outputs
- Select the outgoing product you want to adjust and press Advanced Outputs.
- Block / Allow - never send this output to that destination.
- Prioritise - rank the demands and storage options for this output. This overrides the default nearest-first-then-spill behaviour.
- Reserve (+/-) - keep this many litres in the building at all times. Nothing - distributing, selling, storing, moving or market supply - may take the product below this figure.

### "Move To" Output Mode
- This mode is only available as an output mode when Advanced Routing is turned on and the building is type: Storage
- This mode allows you to move the materials in that storage to another storage that supports it
- By default when you activate this every possible destination is blocked to avoid accidental creation of product loops
- To Active this, select any output, and press Advanced Outputs. You will see a list of supporting destinations on the right (All Blocked) and you can allow buildings as needed. All other advanced output functions are also available for this Move (Prioritise, Reserve etc).
- By Default move to will try to fill the building as much as possible in each cycle. You can set a "Max In" on the receiving buildings inputs to ensure you have space to move multiple products (rather than just completely filling the silo with the first product).

### Before switching Advanced routing off
- Every advanced setting you have made is erased, not merely ignored - all blocks, priorities, reserves, Max In values and targets. Turning Advanced routing back on later gives you a clean slate, so you will need to set it all up again.

## Advanced Rules
These advanced rules apply whether or not Advanced Routing is on, seasonal harvest reserve and AutWater can be turned on/off in settings if desired.

### Sell Modes
For any output in a selling mode you can choose to sell immediately or to wait for the best price. Waiting means the product accumulates in the building until the peak arrives, so make sure there is room for it.

### Seasonal harvest reserve
Switched OFF by default. When you turn it on, an output that is an annual harvest crop will keep roughly a year's worth back to feed your own productions and sell only the surplus. Grass and other crops that regrow through the year keep three months instead. Until the mod has seen a crop harvested it does not know when the next harvest is due, so it falls back to the Reserve months setting.

### AutoWater
Water is supplied automatically to any building that needs it, from the nearest water source, while Auto-Water is on. If there is no placed water source, the system will source it from the nearest body of water (note that if the nearest body of water is distant the distribution cost will be high)]]
    },
    {
        title = "Overview Tab",
        body = [[
The Overview tab puts the entire network in one table: every enrolled building, and every product going into or out of it. It is the place to look when you want to know what is actually happening rather than what a single building is set to.

Each product is tagged (In), (Out) or (In/Out) so you can see at a glance which side of the building it sits on. Silos and sheds are In/Out for everything, since they both receive and supply.

## The four selectors
- Filter by - Nothing (show all), Building, Product, or End product (full chain).
- Show - picks which building or product the filter applies to.
- Timescale - Hour, Month or Year, as on the building tabs.
- Grouping - Off shows one row per building; On combines buildings of the same type into a single summed row, labelled for example "Bakery x2".

End product (full chain) is the most useful of these. Pick a finished product such as cake and the table shows every building and every intermediate product that feeds it, ordered from the finished item back down the chain. It is the quickest way to find the bottleneck or the oversupply in a production line.

## The columns
- RECEIVED - delivered to this building by Distribution Redux.
- LOADED - put into this building by anything that is NOT Distribution Redux: you with a trailer, a bale, an AI helper, another mod.
- CONSUMED (EXP.) - used up, with the expected figure in brackets.
- UNLOADED - taken out of this building by anything that is not Distribution Redux, including a pallet you drive away.
- HELD (CAP) - what is in the building right now, with capacity. Never rescoped by Timescale.
- PRODUCED (EXP.) - made by this building, with the expected figure in brackets.
- DISTRIBUTED - delivered out to consumers.
- STORED/MOVED - sent to storage, or moved to another store.
- SOLD - sold, whether directly or through a market.
- DISTR. COST - what the haulage for this building's deliveries cost. Charged to the sending building only, so the column adds up to the money actually spent rather than counting each delivery twice.

## The expected figures and their colours
CONSUMED and PRODUCED carry the expected amount in brackets, worked out from the recipes of the production lines that are switched on. The figure is coloured green when it is at or very near target, orange when it is slightly short, and red when it is well short. Only productions have a recipe, so animal husbandry and silo rows show a plain figure with no target rather than an invented one.
A red PRODUCED figure is the fastest way to spot a starved line.

## Show Settings
At the bottom of the page you have a button to switch between Show Flows and Show Settings. If you have a production line blocked you can quickly switch to the Show Settings page to see what setting might be blocking it.
Double-Clicking on a line in either view will take you directly to that buildings page.]]
    },
    {
        title = "Pallet Management",
        body = [[
Many outputs are delivered on pallets - boards, planks, vegetables in crates, eggs, wool and so on. To ensure Distribution Redux operates as expected, how pallets work has been completely rewritten 

Distribution Redux will take into account both product held internally in the building as well as any pallet that is on the buildings pallet spawner for both informational displays AND Output Modes. Distribution will always pull from the pallet spawner first and then the internal Storage. If the pallet spawner is blocked product will accumulate in the buildings own internal storage and distribute from there. A pallet removed from the spawner manually is immediately removed from the buildings total.

Buildings without a proper pallet pad in their model - some modded spawners, and a few beehives - fall back to a simple nearest-building rule instead.

## Spawning by hand
- Set the output to Hold Internal. Once it holds at least one full pallet's worth, a Spawn Pallets button appears, both on the Productions tab and on the base-game production screen. Press it to open the spawn window.
- Type - the pallet type. If the output supports only one it is shown for reference; if it supports several, use the arrows to choose.
- Quantity - how many to spawn. The arrows step by one, the -10 / +10 buttons jump in tens, and the total is capped by the stock you hold.
- Spawn drops that many filled pallets at the building's pallet point and removes the matching stock. Cancel closes without spawning.

The button only appears for an output on Hold Internal holding at least one full pallet's worth - below that there is nothing to spawn. The building must also have a pallet spawn point in its model, which most palletising buildings do. In multiplayer the host performs the spawn, so the pallets appear for everybody.

## Pallets from animal pens
In the default game animal pens spawn a pallet and load it with what is in the internal storage every hour regardless of whether there is enough for a full pallet or not (unlike productions). To keep everything consistent by default animal husbandries have been changed to operate the same as productions. This can be changed in the settings to revert back to base game mode, but this may impact on distribution and distribution tracking data (Not Recommended)

There is also an option in the same setting to never spawn pallets. This will prevent pallets from ever spawning and just utilise the buildings internal storage to distribute.]]
    },
    {
        title = "Other Changes to Base Game Mechanics",
        body = [[
## Bunker Silos
- When opening a bunker silo, you now only need to hit R and the mod will remove the entire cover off the silo (no more partial covers that can't be removed)
- Bunker Silos expect you to create the output by loading material in, covering it, waiting for it to ferment, then uncovering it. As such Distribution Redux only shows the output table and options, and will only show stock once the material is uncovered.

## Manure Heaps and Slurry pits
- Manure Heaps and slurry pits can now be placed anywhere on the map, and DO NOT auto-attach to an animal husbandry. To move material from an animal husbandry to these objects, place it, and on the barn select "Store" as the output mode. Manure and slurry will move to those buildings just like any other output.

## Silo Extensions
- Silo Extensions have been extensively rewritten and now operate differently to base game. Silo Extension can now only be placed within 50m of an existing silo, heap or pit and ONLY add storage space to that buidling.

## Markets Manual Tipping
- You can still manually tip/drop off products at your own markets/stalls. Rather than just sell immediately as in base game these products will respect the output mode set on the market. ]]
    },
    {
        title = "Settings",
        body = [[
Global settings live on the Settings tab. They are saved with your SaveGame and synced in multiplayer by the host. Per-building choices always override these globals for that building.

## The options
- Listed in the order they appear on the tab.
- Scope - Range (whole farm) or Proximity (within a radius).
- Animal Husbandry - include or exclude barns, coops, pens and beehives.
- Silos & Pallet Storage - include or exclude bulk silos, pallet and bale sheds, and manure and slurry pits.
- Markets & Kiosks - include or exclude your markets and kiosks.
- Advanced routing - master switch for Advanced Inputs and Advanced Outputs. Off also removes Move To and erases every advanced setting (see Advanced Inputs and Outputs).
- Proximity radius - how far a source reaches in Proximity scope. Default 50 m.
- Consumer buffer - hours of feedstock topped up at each consumer per cycle. Default 2.
- Selling - master on / off for all selling. Off means nothing is ever sold, whatever individual outputs are set to.
- Auto-Water - automatically supply water to buildings that consume it.
- Distribution cost - whether haulage is charged at all.
- Cost rate - the base charge per link per hour. Default 10.
- Cost distance - the distance increment the rate is multiplied by. Default 50 m.
- Seasonal harvest reserve - keep enough feedstock to last until the next harvest, selling only the surplus. Off by default.
- Reserve months (until learned) - how many months to hold back before the mod has learned a crop's harvest window. Default 13.
- Sell at best price - master on / off for best-price selling. Off means everything sells immediately.
- Default sell timing - what a new output uses when you have not set it: wait for the peak, or sell immediately.
- Pallet Spawning - Three options, default game (Spawn partial pallets), Spawn full pallets only (DEFAULT) and Never Spawn Pallets.
- Menu Refresh Rate - Can be adjusted if you are experiencing lag or stuttering on the UI. Manual will activate a refresh button you can use to refresh the UI.
- Debug logging - write detailed activity to log.txt. Leave off for a quieter log.]]
    },
    {
        title = "Support",
        body = [[
## Troubleshooting
- A building is not showing up. Check Scope and the group toggles. Proximity only reaches within the radius, and a building whose group is switched off is removed from the network and its tab hidden.
- Nothing is being delivered. Make sure the source is set to a Distribute mode rather than Hold, the consumer's production line is switched on, and the two are within reach for the current scope.
- A Move To output is not moving anything. Move To starts with every destination blocked. Open Advanced Outputs and activate the destination you want. If a destination shows "Active - Invalid" in red, activating it would create a loop.
- Something arrived but did not sell this hour. That is intended. Product that has just arrived waits one pass so consumers get first refusal.
- An animal pen is holding its eggs or wool. With "Whole pallets from pens" on, a pen accumulates until it has a full pallet before releasing one. Consumers can still draw on the stock while it fills; selling and storing wait for the pallet.
- A factory is not getting water. Water is supplied automatically while Auto-Water is on; if a water-input plant looks starved, confirm the setting.
- No prompt at a building. The left-bracket prompt only shows for buildings that are part of the network. If you excluded that group in Settings, the prompt is gone by design.
- The mod is not behaving as expected. Do not run this alongside other distribution-overhaul mods - they hook the same system and will fight. The mod works with base-game buildings and with modded buildings that follow the standard GIANTS schema; some modded buildings may behave differently and may impact this mod.

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
1. Numerous Bug Fixes (see GitHub for full details).
2. Numerous QoL Additions (see GitHub for full details).
3. Compatibility added for many mods, and the code strengthened to improve mod compatibility overall (see GitHub for full details).
4. Added an Overview tab that allows you to see all distribution activity, and distribution settings, for all buildings in one place (includes filters, and can be set to show all sources and productions contributing to a specific end product)
5. Added Advanced Input and Output management (block, prioritise, reserve stock, fill target, max in).
6. Added the ability to move and sort product between storages (i.e. Silos, Pallet Stores etc) 

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

-- ---- localisation ----------------------------------------------------------
-- The guide is translated PER PARAGRAPH, in translations/translation_<lang>.xml under
-- dr_guide_<slug>_title and dr_guide_<slug>_<n>. TOPICS above stays the English source of
-- truth AND the fallback, so a missing key, a partial translation or an absent language file
-- all degrade to exactly the English guide the mod has always shipped.
--
-- THIS DOES NOT REOPEN 6.6. The guide is still never read from the filesystem by DR (io.open in
-- the GIANTS sandbox TRUNCATED helpGuide.txt to zero bytes, twice over); the ENGINE loads the
-- translation files and DR only ever asks g_i18n for a key.
--
-- KEYING must match scratchpad/gen_guide_l10n.py exactly:
--   * slug comes from the English TITLE, so reordering topics costs nothing;
--   * n counts NON-BLANK paragraphs only, so adding or removing a blank spacer -- much the
--     commonest guide edit -- shifts no key at all.
-- Inserting or deleting a real paragraph does shift the rest of that topic. That is the price of
-- per-paragraph keys; it is contained to one topic, and the l10n checker fails loudly if TOPICS
-- and translation_en.xml ever disagree, so it cannot ship unnoticed.
function DistributionHelpDialog.topicSlug(title)
    if type(title) ~= "string" then return "topic" end
    local out, first = "", true
    for word in title:gmatch("[A-Za-z0-9]+") do
        if first then out, first = word:lower(), false
        else out = out .. word:sub(1, 1):upper() .. word:sub(2) end
    end
    if out == "" then return "topic" end
    return out
end

local function guideText(key, fallback)
    if SmartDistribution == nil or SmartDistribution.l10n == nil then return fallback end
    return SmartDistribution.l10n(key, fallback)
end

function DistributionHelpDialog.localisedTitle(topic)
    if topic == nil or topic.title == nil then return "" end
    return guideText("dr_guide_" .. DistributionHelpDialog.topicSlug(topic.title) .. "_title", topic.title)
end

-- The body with every non-blank paragraph replaced by its translation. Blank lines are STRUCTURE
-- (buildLines turns them into spacer rows) and pass through untouched.
function DistributionHelpDialog.localisedBody(topic)
    if topic == nil or type(topic.body) ~= "string" then return "" end
    local slug = DistributionHelpDialog.topicSlug(topic.title)
    local out, n = {}, 0
    for para in (topic.body .. "\n"):gmatch("(.-)\n") do
        if para:match("^%s*$") ~= nil then
            out[#out + 1] = para
        else
            n = n + 1
            out[#out + 1] = guideText("dr_guide_" .. slug .. "_" .. tostring(n), para)
        end
    end
    return table.concat(out, "\n")
end

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
            -- AUTHORING form (helpGuide.txt)  ->  WIRE form (what TOPICS holds and buildLines reads):
            --     "# Main"        ->  "## Main"      main heading
            --     "## Sub"        ->  "### Sub"      sub-heading
            --     "- Item"        ->  "- Item"       list item, passed straight through
            --     anything else   ->  unchanged      body text
            -- The offset is deliberate and is what keeps this back-compatible: "## " has ALWAYS meant
            -- "a heading" in the wire form, so a TOPICS table written before sub-headings existed still
            -- renders exactly as it did. Longest marker first, or "##" would match the "#" pattern.
            local sub  = line:match("^%s*##%s*(.+)$")
            local main = sub == nil and line:match("^%s*#%s*(.+)$") or nil
            local item = line:match("^%s*%-%s+(.+)$")
            if sub ~= nil then
                cur.lines[#cur.lines + 1] = "### " .. sub
            elseif main ~= nil then
                cur.lines[#cur.lines + 1] = "## " .. main
            elseif item ~= nil then
                -- normalised the same way headings are, so an indented "  - item" still reads as a bullet
                cur.lines[#cur.lines + 1] = "- " .. item
            else
                cur.lines[#cur.lines + 1] = line
            end
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
-- `prefix` goes on the FIRST wrapped line only and `indent` on every continuation, so a bullet that
-- wraps hangs under its own text rather than back under the dash.
local function wrapParagraph(text, maxChars, isHead, out, prefix, indent, level)
    prefix, indent = prefix or "", indent or ""
    local line, first = "", true
    local function emit(s)
        -- `head` is kept alongside `level` so anything still reading the old boolean keeps working
        out[#out + 1] = { text = (first and prefix or indent) .. s, head = isHead, level = level }
        first = false
    end
    for word in text:gmatch("%S+") do
        if line == "" then
            line = word
        elseif #line + 1 + #word <= maxChars then
            line = line .. " " .. word
        else
            emit(line)
            line = word
        end
    end
    if line ~= "" then emit(line) end
end

local LIST_PREFIX = "- "     -- what a list item is marked with
local LIST_INDENT = "  "     -- continuation lines hang under the text, not under the dash

-- Which body lines are LIST ITEMS. This is decided STRUCTURALLY rather than guessed at from the prose,
-- and the guide's own authoring format is what makes that possible: it says "do not hand-wrap long
-- lines", so a prose paragraph is always ONE long line and paragraphs are always separated by a blank
-- line. A RUN of two or more consecutive non-blank, non-heading lines therefore cannot be prose -- it
-- can only be a list. Verified against the shipped guide before it was wired up: 115 lines across 10
-- tabs, every one a genuine list item.
--
-- Two lines inside a run are deliberately left alone:
--   * a first line ending in ":" INTRODUCES the list ("Three things explain most of it:") rather than
--     being an item of it
--   * a line already carrying its own marker (the Changelog's "1." / "2.") is not given a second one
-- A line of nothing but spaces or tabs is a SPACER, exactly like an empty one. Authoring a text file by
-- hand leaves stray whitespace on a "blank" line sooner or later, and the strict `== ""` test silently
-- swallowed it: the line matched no word, emitted no row, and the paragraph break just disappeared.
local function isBlank(s) return s:match("^%s*$") ~= nil end

local function markListItems(paras)
    local isItem, i = {}, 1
    local function isHeading(s) return s:match("^%s*#") ~= nil end
    -- EXPLICIT AUTHORING WINS, WHOLESALE. The guide file now marks its own bullets with "- ", so once a
    -- topic carries even one, this inference is switched off for that topic entirely rather than left to
    -- run alongside. Half-and-half is the dangerous state: a run of "lead-in / - item / - item" would
    -- leave the lead-in as the only unmarked line in a run of three and it would be bulleted as though it
    -- were an item. The inference stays only for content with no explicit markers at all.
    for _, p in ipairs(paras) do
        if p:sub(1, 2) == "- " then return isItem end                -- empty: nothing inferred
    end
    while i <= #paras do
        local j = i
        while j <= #paras and not isBlank(paras[j]) and not isHeading(paras[j]) do j = j + 1 end
        if j - i >= 2 then
            local first = i
            if paras[first]:sub(-1) == ":" then first = first + 1 end
            if j - first >= 2 then
                for k = first, j - 1 do
                    if not paras[k]:match("^%s*%d+%.%s") and not paras[k]:match("^%s*[%-%*]%s") then
                        isItem[k] = true
                    end
                end
            end
        end
        i = (j > i) and j or (i + 1)
    end
    return isItem
end

local function buildLines(body, maxChars)
    maxChars = maxChars or WRAP_CHARS
    local out = {}
    -- paragraphs are collected FIRST: a list item can only be recognised from its neighbours
    local paras = {}
    for paragraph in (body .. "\n"):gmatch("(.-)\n") do paras[#paras + 1] = paragraph end
    local isItem = markListItems(paras)

    for idx, paragraph in ipairs(paras) do
        -- longest marker first: "### " also matches the "## " test
        local sub  = paragraph:sub(1, 4) == "### "
        local main = not sub and paragraph:sub(1, 3) == "## "
        local item = paragraph:sub(1, 2) == "- "
        if isBlank(paragraph) then
            out[#out + 1] = { text = "", head = false }
        elseif sub or main then
            -- NOT upper-cased: the base game renders its headings in normal case and distinguishes them
            -- by weight and size, which is what the page does. Shouting them was the mod's own invention.
            --
            -- EXACTLY ONE blank row above a heading, never two. The guide already puts a blank line
            -- before almost every heading, and this used to add a second unconditionally -- so the gap
            -- was two full row heights (~54px at the 27px pitch) and read as a break in the page rather
            -- than as a heading attached to what follows it. Collapsing instead of simply dropping the
            -- injected row keeps the gap correct either way: a heading written with no blank line before
            -- it still gets one.
            if #out > 0 and out[#out].text ~= "" then
                out[#out + 1] = { text = "", head = false }
            end
            wrapParagraph(paragraph:sub(sub and 5 or 4), maxChars, true, out, nil, nil,
                          sub and "h2" or "h1")
        elseif item then
            -- explicit "- " from the guide file: strip the author's marker and re-apply the canonical
            -- one, so spacing is identical whether the bullet was written by hand or inferred below
            wrapParagraph(paragraph:sub(3), maxChars - #LIST_PREFIX, false, out, LIST_PREFIX, LIST_INDENT)
        elseif isItem[idx] then
            -- the prefix costs width, so the wrap has to give it back or a bullet runs wider than prose
            wrapParagraph(paragraph, maxChars - #LIST_PREFIX, false, out, LIST_PREFIX, LIST_INDENT)
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
    self.lines = buildLines(DistributionHelpDialog.localisedBody(TOPICS[index]))
    if self.bodyTitleElement ~= nil then
        self.bodyTitleElement:setText(DistributionHelpDialog.localisedTitle(TOPICS[index]):upper())
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
        if nameCell ~= nil and topic ~= nil then nameCell:setText(DistributionHelpDialog.localisedTitle(topic)) end
    else
        local row = self.lines[index]
        local lineCell = cell:getAttribute("bodyLine")
        if lineCell ~= nil then
            lineCell:setText(row ~= nil and row.text or "")
            -- Emphasise headings without per-row profile swapping. `textBold` is a FIELD read at draw
            -- time -- TextElement has no setTextBold method, so the pcall'd call that used to be here
            -- failed silently on every row and nothing was ever bold. Set on BOTH branches: cells are
            -- recycled, so a bold left applied bleeds onto the next body line to reuse the row.
            lineCell.textBold = (row ~= nil and row.head == true)
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
