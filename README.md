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

Fixed
1) Corrected some broken calculations caused by how pallets work on the Building information screens. 
2) Added more information to the information screens for each building (e.g. added input consumed/month)
3) Removed Manure and slurry as outputs on animal husbandry buildings that don't support them.
4) Cow farms with feeding robots now function correctly and use the Input bins rather than skipping straight to adding feed to the barn directly.
5) Fixed Animal Husbandries that produce pallets to ensure they don't spawn pallets when Hold - Internal is selected.
6) Animal Pastures (ie no barn) no longer produce and store manure in line with base game functionality
7) Updated how buildings with shared (pooled)storage function/show in the UI. If a silo is filled over the reserved amount for a specific product manually, the remaining products reserved levels will adjust to reflect what room is left rather than showing volumes that simply aren't available.

Added
1) Support added for the Grazing Pastures Mod
2) Added numerous checks to reduce the number of buttons and options across the UI (e.g. if the output of a production has no storage destination available, Store will no longer be shown as an option)
3) Animal Husbandries that spawn pallets can now have pallets stored internally and spawn pallets at user request.
4) Firmed up the detection and management of modded animal husbandries to better support mods in general. Note this may help with some mods and not others, please raise a GitHub issue if you have a mod that is not working.
5) Support Added for modded buildings in the Nordkirchen_x4 Map Mo
6) Added support for Bunker Silo's and Bulk Halls

New Features
1) Added advanced distribution input and output configuration options. Feature can be turned off in settings. If feature is turned off, or no advanced option is applied the system will work in the default mode as per the last patch. Advanced options include:
	a) Ability to Block, proportion reserved storage for products (for pooled storage only) and set target levels for inputs (overrides min required demand and tries to fill to the set level instead).
	b) Ability to block and prioritise a buidlings outputs.    
	c) Added an indication in the buidling information that indicates wether the input/output is currently active, whether it is idle, or actually feeding product and if the product is blocked (applies to both inputs and outputs)
2) Added Move To option for Silo's/Storages. Allows storages to move product to other storages that support that product. For example you can have remote drop-off points near fields all over the farm and sort and move them to a central storage location(s).
	a) the input and output advanced settings also apply to these distributions allowing extensive configuration
	b) The system automatically detects if a change in settings will create an infinite loop between storages (e.g. A-->B-->A, A-->B-->C-->A) and will prevent you from changing whatever setting you are trying to adjust. A message will appear at the top of window indicating that you tried to set something that would create a loop.

Notes
1) Storages with pooled stroage spaces will now reserve a portion of that space for each type of possible input by deafult. For example a silo with 400,000l of storage and 10 inputs will automatically be set to only store 40,000l of each type by default. You will need to change the input settings to store more of a particular type of product (e.g. block or set to zero the storage reserved for all other products and max out wheat). If a silo is not getting the amount you expect this is the first thing to check! Note that the reserved space only applies to distirbution, manually filling the silo works as per base game (can put as much of anything you want in up to the max storage space), however if you overfill a particular product, distribution will stop feeding any additional product until the stored amount goes below the reserved storage space.
2) Many people have reported issues with Manure Heaps/Slurry Pits and the related extensions. To keep everything consistent the mod very much modifies how these items work. If you just place the manure pit near a cow farm for example, nothing will happen unlike base game. You now need to set the manure/slurry output on the farm to a Store To mode to have the output go into the heap/pit. Extensions now can only be placed within 50m of a matching storage and will just increase the manure stored in the nearest heap/pit.
3) Due to the changes in how options are made available per product (See added 2) the cycle all outputs button had to go. I might see if i can find an elegant way to re-add it in future (don't hold your breather though :))
4) By Default setting a storage output set to Move To does nothing unless you sepcify where you want it to move to in the advanced settings. This is to avoid the system automatically creating infinite loops when the options is selected. If you have something set to move to, but nothing is moving check teh advanced output settings.
5) Bunker silo's for silage are a bit weird. The distribution system will work, however the way it updates the heap level is a bit werid. If DR removes silage from the heap a part of the heap will change colour but not level. A game reload or picking up some remaining silage with a tractor will update the fill level properly.