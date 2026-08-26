# CHANGELOG

Changelog Last updated: 21/08/2026

<h2><b>1.1.0.1 Release Candidate</b></h2>

Fixed
1) Fixed Extensions only adding storage to the Output Section of the UI and blocking incoming material from filling to capacity. 15/8
2) Fixed Never spawn pallets setting from stopping pallets being bought at stores. 15/8
3) Distribution costs moved to the "Other" category on the finance page to hopefully make it easier to see. 16/8
4) Fixed status displays being delayed 1 cycle too late. (21/8)
5) Redid the calculation for sell at best price. There was some issues with markets that should now be resolved. 21/8
6) Fixed modded buildings that are both a silo and a production not showing the silo side in storages.(24/8)
7) Fixed an issue with the advanced output screen when in dual mode outputs (e.g. Distribute + Move To) that prevented you modifying settings on some lines. (24/8)
8) (NEW) Fixed animal husbandries showing only the total food amount rather than the individual food amounts stored. (26/8)
9) (NEW) Fixed an issue with building icons not showing in the UI due to no building menu icon being defined in mods. Now checks and has multiple fallback options. (26/8)

Added
1) Added L10n Translation Layer to the mod (See notes above for contributors). 15/8
2) DR UI will now resize to match you screen resolution rather than leaving deadspace on the screen. 15/8
3) Added the ability to select the pallet type and spawn partial pallets througthe pallet spawner. 15/8
4) Added a setting allowing map storages to be used in the distribution network (NOTE: Default off) 15/8
5) Added 2 new settings to the settings page allowing you to set the default input & output modes for new buildings (either Hold or Distribute for outputs, and either block all or allow all for inputs) 16/8
6) Added arrow keys to the outputs to make changing modes easier. Can now go backwards or forwards through the options. If you have a specific output selected you can also use "Z" and "X" keys to scroll backwards and forwards for the selected output. 16/8
7) Added Full Chinese Translation 16/8
8) Added Finnish Translation (All Except User Guide) 16/8
9) Fixed the input default setting resetting all existing buildings to blocked inputs. Was a race condition on savegame load that applied the default before all buildings where loaded. 20/8
10) Added a fix to the base game mechanic that under some circumstances allowed overfilling of silos. (20/8)
11) Status display will now take into account the time period selected. e.g. If month is selected the status will reflect whether the distribution did anything in the last month, hourly if it did anything in the last hourly cycle etc. 21/8
12) Changed how the "Sell" setting modifies how the mod operates. If you turn off sell in the settings, everything will revert to manual transporting to sell only. Markets will revert to pre-mod functionality (Seel immediate). 21/8
13) Added an API Layer to support add-on mods (no gameplay change) 24/8
14) (NEW) Reworked the UI's to be more user friendly. This is the first cut of the new UI, feedback welcome, i have described the new storage bar included in the UI below as a new feature (It's complicated!). (26/8)
15) (NEW) You can now open the DR menu while in a vehicle. (26/8)

NEW FEATURES
1) NOTE THIS IS VERY EXPERIMENTAL SO PLEASE TEST ON A COPY OF YOUR SAVEGAME FIRST! Added a new feature to increase support for modded buildings and change how they work with DR to make more sense. 
a) All buildings now go through a check to identify whether they are a production, pallet/bale storage or silo, or importantly a combination of any/all of those. DR will treat combo's as individual buildings of each type. For example, where a modded building has a cheese production as well as a pallet store it will show up in DR under productions AND under storage. Each element of the building (Silo, Pallet store, production) will appear in the DR UI in the correct tab and each can be configured individually (with one exception, see below).
b) Where a building has a production and a silo that use/store the same input, the input is linked (wether it is a linked input is now shown on the input table). Any change made on either page will be represented on the other page. This effectively allows the product to be both an input to the production AND a product that can be stored and moved in the silo (e.g. you can still set output mode for the product in the silo). The silo will feed the production first regardless of the output mode setting on the silo, after feeding the production, the silo output mode will then be applied. For example if the production line is active, and the output on the silo is set to sell, the silo will feed the production first then apply the sell rule.
b) Many mods add a 1:1 production to a silo to enable distribution, obviously this messes with DR and is no longer needed, so to avoid this, if a silo has 1:1 Production lines the productions are supressed entirely and DR will see it as a standard silo and show it in the storage tab with the standard DR output modes (note at this stage the productions remain on the normal UI but will look at suppressing that later if possible). Note that if you enable a production line that is no longer needed in the base UI, you will get charged a production cost for the hour even though it does nothing, but DR will re-disable that line in the next cycle silently. 
c) I have also added the ability to move product between a silo and a pallet store where the product is palletisable using the move to output mode (and yes, if a building is both a silo and a pallet store you can move product between the different storages).
2) Added a new storage indicator on all UI elements. This replace the old number fields and consolidates them into a total view of what is happening with that storage. 
a) For each input and output there is a green bar that shows the amount of that product stored as a ratio fo the total storage available (see note below on storage types). That will be followed by a red bar that shows how much of other products is taking up space in that storage. The remaining gray part of the bar represents how much more of that product you could put in there.
b) For inputs, if you set a max amount in advanced inputs an orange line on the bar will indicate the max you set for that product (ie the green fill bar will never exceed that line), similarly if you set a target amount (not applicable to silo's) a light blue line will indicate the amount you set as the target.
c) For outputs, if you set a reserve amount for that output, that will be indicated by a dark blue line on the bar for that output.
NOTE: Storage type becomes very important to understanding this bar. Some storages are Pooled (ie there is an amount of total storage and any of the products placed in there will consume that storage). Then there are individual storages where the storage space is defined per product (you will never see a red bar on these). In some cases, advanced or modded buildings will have multiple storages and product can go into multiple storage types (e.g. Drive-In mod has 1 liquid and 2 general storages with some products able to go into all three). The UI will show this in the Storage Type column, e.g. Pool 1+2. The bar will represent the totals and fill levels for both of those pooled storages for the product. If some numbers seem off, check the storage type. EXAMPLE: The Drive-In Mod Silo has 25M litre total storage, but it is broken into 3 sub-storages. It has a general storage that takes pretty much everything (10M L), a smaller 5M L silo that holds a subset of those products (no idea why, ask the mod maker lol), and a 10M litre liquid store. Milk is flagged as being able to be stored by both the general storage and the liquid storage (again no idea why) so is marked Pool 1+3 with a total storage of 20M L (only the small 5M L tank cannot be used). Sugar beet on the other hand can only use the general storage so shows Pool 1 and only has a max capacity of 10M L.

<h2><b>V1.1.0.0 Release</b></h2>

Fixed
1) Corrected some broken calculations caused by how pallets work on the Building information screens. 
2) Added more information to the information screens for each building (e.g. added input consumed/month)
3) Removed Manure and slurry as outputs on animal husbandry buildings that don't support them.
4) Cow farms with feeding robots now function correctly and use the Input bins rather than skipping straight to adding feed to the barn directly.
5) Fixed Animal Husbandries that produce pallets to ensure they don't spawn pallets when Hold - Internal is selected.
6) Animal Pastures (ie no barn) no longer produce and store manure in line with base game functionality
7) Updated how buildings with shared (pooled)storage function/show in the UI. If a silo is filled over the reserved amount for a specific product manually, the remaining products reserved levels will adjust to reflect what room is left rather than showing volumes that simply aren't available.
8) Fixed distribution and selling of non-market items (e.g. electric charge) to support mods that can consume them as well as sell them.
9) Productions are no longer free, daily cost for productions has returned!
10) Fixed issues caused by overlaping husbandy and/or production pallet control areas. Pallets are now limited to the spawn box of the production and properly owned by the producing buidling.
11) Water extensions for greenhouses can now be placed again and add water storage to the greenhouse corrcetly.
12) In-Game Help has been completely rewritten to match the new version.
13) Animal Husbandries should no longer spawn partial or empty pallets. (30/7)
14) Fixed Bunkers to not show inputs (you manually load it, cover it, let it ferment and then uncover it... So there are no DR Inputs), and read filltypes properly so that modded ones work correctly for outputs. (30/7)
15) Standard Game UI now shows animal pen storage correctly rather than just being zero.
16) Fixed an issue with setting a reserve on a building that spawns pallets, pallets where not being taken into account when the reserve test was being performed resulting in the building waiting until it had maxed out the pallets AND hit the reserve target with the internal storage. Now takes into account pallets on the pallet spawner. (31/7)
17) Fixed an issue where productions that "could" supply a demand but weren't (ie the line was inactive) where showing the inputs for that building in the end product filter. (30/7)
18) Fixed the advanced inputs not showing for the markets/kiosks, removed the advanced outputs as they don't apply to markets. (30/7)
19) Streamlined many of the hourly calculations to address stuttering when sleeping or passing through the hourly cycle reported by some users (more options here to streamline so will continue to monitor). (2/8)
20) Fixed an issue where if a productions pallet spawner was blocked the product would just store internally and never be able to be distributed (now distributes from internal storage if no pallets). (2/8)
21) MArkets now properly take the default sell type (immediate or Best price) as set in the settings page. (3/8)
22) Bunker Silo's now show correct amount once opened in DR. (3/8)
23) Bunker Silo Level now correctly render when DR takes out material. Previously the colour would change but the heap level would stay until you interacted with the remaining material with a vehicle. (3/8) 
24) Phase 2 of performance improvements, should fix stutters or freezes on very large production setups. Just to put the scale of the improvement into context there is roughly a 4000x time improvement in processing time (Extreme example: what would have taken 9.5 mins previously, now takes 0.14s). (4/8)
25) Fix for dedicated servers not maintaining settings across sessions. (4/8)
26) Fix for certain modes resetting to "Hold" each cycle on dedicated servers. (5/8)
27) Fix for seasonal reserve only applying to Sell modes, not Market Supply Modes (5/8)
28) Fixed MultiFruit Silo's that supported manure and slurry being incorrectly classified as animal husbandry objects (6/8)
29) Fixed Pallet/Bale store issue where under certain circumstances non-bale products would be stored as bales instead of pallets (6/8)
30) Fixed an issue where if a modded extension (e.g. LDC Silo Extension) was added to a base game silo, the base game silo would inherit all of the additional filltypes the extension supports. (6/8)
31) Redid how pooled storage is handled and displayed to reduce confusion. Pooled Storage now works the same way as base game, but allows you to set the maximum storage for each input type. (6/8)
32) storage now shown in kL in the UI where above 1000l stored, to help fit all the info on the UI. (6/8)
33) Fixed some issues with silo extensions bleeding into silo's it wasn't supposed too. (6/8)
34) Fixed productions with remaining produced products on an inactive line not being able to distribute. (8/8)
35) Fixed DR settings being saved globally instead of per savegame. (8/8)
36) Help Guide Updated (8/8)
37) Fixed a mod icompatability that was stopping fields from growing (9/8)
38) Additional fix for productions not supplying to markets when the line was inactive even if there was still stock in the production (9/8)
39) Fix for DR settings not being saved the first time a fresh savegame was saved.(9/8)

Added
1) Support added for the Grazing Pastures Mod
2) Added numerous checks to reduce the number of buttons and options across the UI (e.g. if the output of a production has no storage destination available, Store will no longer be shown as an option)
3) Animal Husbandries that spawn pallets can now have pallets stored internally and spawn pallets at user request.
4) Firmed up the detection and management of modded animal husbandries to better support mods in general. Note this may help with some mods and not others, please raise a GitHub issue if you have a mod that is not working.
5) Support Added for modded buildings in the Nordkirchen_x4 Map Mo
6) Added support for Bunker Silo's and Bulk Halls
7) Added support for the FS25_Fed_Produktions_Pack Mod.
8) Made UI numbers update realtime rather than only on UI close and reopen.
9) Adjusted how inputs and outputs are shown on the production UI. Inputs and outputs will now only show for production lines that are turned on.
10) Added an option in settings to make animal pens spawn pallets the same as production (i.e. wait until 1000l produced then spawn pallet). This ensures only full pallets are spawned and makes reporting of volumes more accurate, but can be turned off to revert to the original.
11) Added ability to track manual adding or removal of material in the Overview (e.g. removig a plalet from a pallet spawner or removing/adding grain to silo with a trailer).
12) Added the ability to manually tip product to markets/kiosks and have it obey the output mode (previously would just immediately sell regardless of the setting). (30/7)
13) Added a new mode to the overview that allows you to see all the advanced settings of each building/product (e.g. reserved amounts, output mode, etc etc) (31/7)
14) New setting option for pallets that allows you to tell the game to never produce pallets from productions/animal husbandries. Note that distribution will still occur from the internal storage of that building, Pallets can still be spawned manually as needed (This is the only way to have pallets spawn if the setting is on). (2/7)
15) Added a feature that opens the whole bunker silo when you press R on any part of the bunker. You no longer need to interact with the silage with a vehicle to get the bunker to fully open. (3/8)
16) Added a new setting to set the refresh rate of the UI in case you still have issues with stuttering or freezing (4/8)
17) When advanced routing is activated in the settings (on by default), the Building UI's will only show inputs/outputs that are either active (Not Blocked) or have material in storage. If an input is Blocked AND is empty, that material will not be shown. Instead an extra line will be visible that shows "+ X Inputs that are blocked (see Advanced inputs for details)" (4/8)  

New Features
1) Added advanced distribution input and output configuration options. Feature can be turned off in settings. If feature is turned off, or no advanced option is applied the system will work in the default mode as per the last patch. Advanced options include:
	a) Ability to Block, proportion reserved storage for products (for pooled storage only) and set target levels for inputs (overrides min required demand and tries to fill to the set level instead).
	b) Ability to block, prioritise and set a reserve for a buildings outputs.    
	c) Added an indication in the buidling information that indicates wether the input/output is currently active, whether it is idle, or actually feeding product and if the product is blocked (applies to both inputs and outputs)
2) Added Move To option for Silo's/Storages. Allows storages to move product to other storages that support that product. For example you can have remote drop-off points near fields all over the farm and sort and move them to a central storage location(s).
	a) the input and output advanced settings also apply to these distributions allowing extensive configuration
	b) The system automatically detects if a change in settings will create an infinite loop between storages (e.g. A-->B-->A, A-->B-->C-->A) and will prevent you from changing whatever setting you are trying to adjust. A message will appear at the top of window indicating that you tried to set something that would create a loop.
3) Added a new Tab to the UI that provides an overview of all production and distribution numbers such as recieved, consumed, produced, etc. List can be filtered as needed. Number on the specific building UI have been simplified to reduce space consumed, details are now on this new UI. Filtering includes:
	a) Filter by Building (see just inputs and outputs for one building)
	b) Filter by Product (See all inputs and outputs for all buildings that have that product)
	c) Filter by End Product (show entire chain leading to that product)
	d) Combine Buildings (if you have multiple buildings of the same type will sum the numbers)
	e) Note that lines only show if there is some activity/storage related to them, to keep the list a reasonable length.

Notes
1) Many people have reported issues with Manure Heaps/Slurry Pits and the related extensions. To keep everything consistent the mod very much modifies how these items work. If you just place the manure pit near a cow farm for example, nothing will happen unlike base game. You now need to set the manure/slurry output on the farm to a Store To mode to have the output go into the heap/pit. Extensions now can only be placed within 50m of a matching storage and will just increase the manure stored in the nearest heap/pit.
2) Due to the changes in how options are made available per product (See added 2) the cycle all outputs button had to go. I might see if i can find an elegant way to re-add it in future (don't hold your breathe though :)
3) By Default setting a storage output set to Move To does nothing unless you specify where you want it to move to in the advanced settings. This is to avoid the system automatically creating infinite loops when the options is selected. If you have something set to move to, but nothing is moving check the advanced output settings.

<h2><b>v1.0.0.2 - Released</b></h2>
1) Buildings can now be renamed: all buildings in the distribution network can be given a custom name from the base-game construction menu (silos, sheds and pits included, which the game does not normally allow). Distribution Redux uses that name throughout its menu, with the original building name shown beneath it as a reference.
2) Fixed the Manure Heap and Slurry Pit listing each other's product: the Manure Heap now shows only Manure and the Slurry Pit only Slurry.
3) Fixed the Manure Heap and Slurry Pit showing no incoming product; they now list what actually flows into them.

<h2><b>v1.0.0.1 - Released</b></h2>
1) UI fixes and consistency edits.
2) Added Markets and Kiosks to the distribution system.
3) Fixed the sell-at-best-price logic that could sell too early on the first pass.
4) Added the Hold Internal output mode: keep a production's bulk product in the building instead of auto-spawning pallets.
5) Added manual pallet spawning from a Hold Internal output's held stock - a pop-up lets you pick the pallet type and quantity (capped by what's stored), available from the Distribution Redux menu and the base-game production screen.