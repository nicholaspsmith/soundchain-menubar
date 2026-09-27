# SoundChain end-to-end checklist

Run with music playing. Record the date, macOS version and result of each step.

1. Fresh start: move `~/Library/Application Support/SoundChain` aside, launch. Permission prompt appears; allow it. Green caterpillar, audio unchanged.
2. Add AUDelay; echo is audible. Bypass on/off from the menu works.
3. Reorder two effects by dragging; the dragged row stays centred on the cursor; order persists across relaunch.
4. Switch output between the built-in speakers or AirPods and the Scarlett Solo (and back) while playing. Audio follows within about a second each time; no restart loop in the menu status.
5. Sleep the Mac for at least one minute, wake it. Audio resumes processed without touching SoundChain.
6. `pkill -9 SoundChain`: unprocessed audio continues.
7. Relaunch: chain and each plugin's settings are restored (open an editor to confirm).
8. Corrupt the chain file (`echo junk > ~/Library/Application\ Support/SoundChain/chain.json`), relaunch: empty chain, menu names the `.corrupt-` backup file.
9. Restore the moved-aside folder from step 1.
