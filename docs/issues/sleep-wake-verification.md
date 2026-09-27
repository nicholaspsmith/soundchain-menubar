# Verify SoundChain across sleep and wake

End-to-end checklist step 5 has not been run yet.

**Steps**
1. Play music with at least one effect in the chain.
2. Sleep the Mac for at least one minute, then wake it.

**Expected**
Audio resumes processed without touching SoundChain. The tap engine rebuilds on
`NSWorkspace.didWakeNotification` (forced restart) and on the output device's
is-alive and sample-rate listeners.

**If it fails**
Note the output device (AirPods reconnect after wake is the likeliest trouble), the
menu's status line, and `log show --predicate 'process == "SoundChain"' --last 10m`.
