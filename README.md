# GMETER
  
GMETER is a small Lua script for DCS World that draws an on-screen bar showing G force acting on your body.  
  
You cannot feel G in a simulator, and your aircraft's own G meter may not always be visible (such as in a earlier Cold War aircraft). GMETER is not a repeater for the G force gauge in your aircraft. It is a rough representation of what your body would be telling you, in a place you can see without having to look away from what you are doing.  
  
I made this because Vulture mentioned that the seat-of-your-pants feeling was missing from DCS, and he suggested that we just needed something like this.  
  
This mod was built with generative AI assistance. The idea, the design decisions and direction are mine.

## What it does

The bar grows up from a zero mark to a positive G, and down for a negative one. There is a tick mark on the 1 G position.   
  
**Bar Length** -- is the total magnitude of the G force vector. Pulling a turn, lighting your burner, a cat shot. These all will grow the bars length in ways that try to represent what you are feeling.  
  
**Colour** -- is driven by the vertical G force alone. This is the G force that causes you to black out. It may not be as much force as you feel from acceleration, but it has the larger effect on your body.

The bar is anchored around the 1 G mark as thats the "normal" point. Going in either positive or less than 1 G is where things change.  
  
A fast pull reads high, then settles back into the true value as you hold it. This deliberately represents the effect of increased effects of a sudden onset of G force.  
  
## Examples

A hard pull. Note that it spikes past where it settles, and briefly reaches the limit colour on a pull that settles well below the ceiling. That is the onset response.

![Hard pull](media/pull-hard.gif)

The same G, pulled smoothly over a longer period of time. It never reaches the limit colour and comes back without dipping.

![Smooth pull](media/pull-smooth.gif)

## Installation

Extract the zip into `Saved Games\DCS\Scripts`. The archive already has the folder structure, so you should not need to place any files manually.  
  
It puts the following files into the following locations:
- `gmeter-hook.lua` into `Scripts\Hooks\`  
- `GMeter.lua` and `GMeterWindow.dlg` into `Scripts\GMeter\`


`GMeter.lua` holds the logic. `GMeterWindow.dlg` describes the layout. `gmeter-hook.lua` is a loader and contains no logic.  
  
Start a flight (single player, multiplayer, or instant action) in DCS and a config file is created in `Saved Games\DCS\Config\GMeterConfig.lua` the first time you run it.   
  
By default **CTRL + SHIFT + G** shows and hides the GMETER.  
  
## Configuration

Everything is in `Config\GMeterConfig.lua`, which is documented with comments. Your convfig file is not overwritten once made.  
  
Changes are detected when you restart a mission, or you can enable `watchFiles` to `true` and then it will auto detect changes when you save the config file within about a second. This should not be left on, but it is useful when adjusting the location of the bar.  
  
Important config options:
- `layout.scale` allows you to multiply the sale of everything. Set it at 2 and you get a double resolution gauge for a high resolution display.
- `position` lets you place where the gauge is. Negative values measure from the right and bottom. 
- Colours are `0xRRGGBBAA`, alpha is used to lower the opacity of the bar. The default setting has the bar become less transparent as the value increases.
- `maxG` is the point where the bar caps out and shows the tolerance limit.

The gauge cannot be moved with the mouse, so use the `position` variable to adjust it.

## Problems, Troubleshooting
Check the logs at `Saved Games\DCS\Logs\GMeter.log`. Everything gets logged there, including reasons that it isn't drawing.  
  
The most likely cause is a server blocking the export api with `allow_ownship_export = false`. The script will simply draw nothing.

You must also be in an aircraft in cockpit view to see the bar.

If the colours are not using the ones you changed it to, then you may have missed the `0x` prefix in the colour code and it is reverting to default colour values.  
  
## Licence and stuff
No warranty, express or implied. It is a script that draws a rectangle, but it runs on your machine. If it breaks something, that is on you. Read the source to figure out how it works. Report bugs on github.

GMETER is released under the GNU General Public License v3.0 only. See LICENSE.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of merchantability or fitness for a particular purpose. See the GNU General Public License for more details. Use it at your own risk.

