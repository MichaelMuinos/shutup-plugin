# Shutup: A SourceMod Plugin
Allows players to be muted and gagged by name with a specified time limit.
The punishments are carried out in real time, meaning once the player's punishment
time limit has expired, they will be unmuted/ungagged immediately.

## Usage
### Muting
Mute a player for a specified time limit
```
sm_p_mute <time> <name>
```
Mute a player forever
```
sm_p_mute 0 <name>
```
Unmute a player
```
sm_p_unmute <name>
```

### Gagging
Gag a player for a specified time limit
```
sm_p_gag <time> <name>
```
Gag a player forever
```
sm_p_gag 0 <name>
```
Ungag a player
```
sm_p_ungag <name>
```

### Silencing (Executes both a mute and gag)
Silence a player for a specified time limit
```
sm_p_silence <time> <name>
```
Silence a player forever
```
sm_p_silence 0 <name>
```
Unsilence a player
```
sm_p_unsilence <name>
```




