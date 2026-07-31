# FS25-Distribution-Redux
Replaces Farming Simulator 25's standard distribution system with a smarter, demand-driven logistics network.
Distribution Redux automatically moves resources between productions, animal husbandries, silos, and storages based on actual demand. It prioritises the nearest available source, supports automatic feed, straw, and water distribution, and gives you full control over how each output is handled.

v1.0.0.1 - Released
- UI fixes and consistency edits.
- Added Markets and Kiosks to the distribution system.
- Fixed the sell-at-best-price logic that could sell too early on the first pass.
- Added the Hold Internal output mode: keep a production's bulk product in the building instead of auto-spawning pallets.
- Added manual pallet spawning from a Hold Internal output's held stock - a pop-up lets you pick the pallet type and quantity (capped by what's stored), available from the Distribution Redux menu and the base-game production screen.

v1.0.0.2 - Released
- Buildings can now be renamed: all buildings in the distribution network can be given a custom name from the base-game construction menu (silos, sheds and pits included, which the game does not normally allow). Distribution Redux uses that name throughout its menu, with the original building name shown beneath it as a reference.
- Fixed the Manure Heap and Slurry Pit listing each other's product: the Manure Heap now shows only Manure and the Slurry Pit only Slurry.
- Fixed the Manure Heap and Slurry Pit showing no incoming product; they now list what actually flows into them.

V1.1.0.0 Release candidate Changelog (To Date)
Changelog Last updated: 30/07/2026

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
16) (NEW) Fixed an issue with setting a reserve on a building that spawns pallets, pallets where not being taken into account when the reserve test was being performed resulting in the building waiting until it had maxed out the pallets AND hit the reserve target with the internal storage. Now takes into account pallets on the pallet spawner. (31/7)
17) (NEW) Fixed an issue where productions that "could" supply a demand but weren't (ie the line was inactive) where showing the inputs for that building in the end product filter. (30/7)
18) (NEW) Fixed the advanced inputs not showing for the markets/kiosks, removed the advanced outputs as they don't apply to markets. (30/7) 

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
13) (NEW) Added a new mode to the overview that allows you to see all the advanced settings of each building/product (e.g. reserved amounts, output mode, etc etc) (31/7) 

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
1) Storages with pooled stroage spaces will now reserve a portion of that space for each type of possible input by deafult. For example a silo with 400,000l of storage and 10 inputs will automatically be set to only store 40,000l of each type by default. You will need to change the input settings to store more of a particular type of product (e.g. block or set to zero the storage reserved for all other products and max out wheat). If a silo is not getting the amount you expect this is the first thing to check! Note that the reserved space only applies to distirbution, manually filling the silo works as per base game (can put as much of anything you want in up to the max storage space), however if you overfill a particular product, distribution will stop feeding any additional product until the stored amount goes below the reserved storage space.
2) Many people have reported issues with Manure Heaps/Slurry Pits and the related extensions. To keep everything consistent the mod very much modifies how these items work. If you just place the manure pit near a cow farm for example, nothing will happen unlike base game. You now need to set the manure/slurry output on the farm to a Store To mode to have the output go into the heap/pit. Extensions now can only be placed within 50m of a matching storage and will just increase the manure stored in the nearest heap/pit.
3) Due to the changes in how options are made available per product (See added 2) the cycle all outputs button had to go. I might see if i can find an elegant way to re-add it in future (don't hold your breathe though :)
4) By Default setting a storage output set to Move To does nothing unless you sepcify where you want it to move to in the advanced settings. This is to avoid the system automatically creating infinite loops when the options is selected. If you have something set to move to, but nothing is moving check teh advanced output settings.
5) Bunker silo's for silage are a bit weird. The distribution system will work, however the way it updates the heap level is a bit werid. If DR removes silage from the heap a part of the heap will change colour but not level. A game reload or picking up some remaining silage with a tractor will update the fill level properly.