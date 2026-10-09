-- Golden fixtures: authority records signed by the addon's Crypto.lua, for the smoke test and the server's tests.
-- The first thirteen are the server's go_signed.json records signed again here, byte for byte the same; the rest are the
-- addon's own. Keys: the app seed and GUIDs in go_keys.json (test values, never a real player's).
return {
	keys = {
		{ appSeed = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", guid = "Player-4613-00ABCDEF", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM", kid = "37fFOGvi" },
		{ appSeed = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", guid = "Player-1-00000001", pk = "eG5/N/0inyG/ZzWArEoBVhzjmHMHtxkfBE/g6Y0RgwI", kid = "S7NmBAw2" },
	},
	records = {
		{ kind = "bounty", id = "Duhpope Mon:1", origin = "Duhpope Mon", seq = 1, prev = "0", t = 1790370000, hash = "adf8675a", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM",
			data = { ["amount"] = 500000, ["class"] = "ROGUE", ["faction"] = "Horde", ["level"] = 30, ["mapId"] = 1434, ["seenAt"] = 1759999000, ["sig"] = "137fFOGviRqu7U8JKBBUs2kqtThhnbajk+X0HO4An68Fw8l6dzzGpNg7lldChjGmxW1UfNNenUyOzca6sZ9QQEswKKxqlAw", ["target"] = "Player-4395-0A1B2C3D", ["targetGuild"] = "Red Dawn", ["targetName"] = "Gankalot", ["x"] = 0.43209999999999998, ["y"] = 0.67889999999999995, ["zone"] = "Stranglethorn Vale" } },
		{ kind = "raise", id = "Duhpope Mon:2", origin = "Duhpope Mon", seq = 2, prev = "adf8675a", t = 1790370037, hash = "4cc83990", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM",
			data = { ["amount"] = 2147483647, ["bounty"] = "Duhpope Mon:1", ["sig"] = "137fFOGvir8VVcnMTi0HFdb09b+/LgA3tNMrEADzspgUOIjMvydtlHbx4irASEtIEmBkhN5hodwIYqXqCRjsXI6zAzYmRCg" } },
		{ kind = "withdraw", id = "Duhpope Mon:3", origin = "Duhpope Mon", seq = 3, prev = "4cc83990", t = 1790370074, hash = "1ea03692", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM",
			data = { ["bounty"] = "Duhpope Mon:1", ["reason"] = "", ["sig"] = "137fFOGvi3ARxoY2DMlz/j17H2UEI+13/kt/8/jdP+xTquKyC8oQwULgGoYsjOOgpKbSUNLQqbmWceKh1qkTJJk+NdX05BA" } },
		{ kind = "pass", id = "Duhpope Mon:4", origin = "Duhpope Mon", seq = 4, prev = "1ea03692", t = 1790370111, hash = "ce154001", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM",
			data = { ["bounty"] = "Duhpope Mon:1", ["note"] = "a=b; c==d", ["sig"] = "137fFOGvicr5/vdb9936Ln+cDsxisqsy7MCJRM8bGsCs/2vyLNfLVjT1B3e10qUd+uPGgdm7y/Lkg0nGLigLnd54Xsbc9Cw", ["to"] = "Zoë Ångström" } },
		{ kind = "hunt", id = "Duhpope Mon:5", origin = "Duhpope Mon", seq = 5, prev = "ce154001", t = 1790370148, hash = "0b513e65", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM",
			data = { ["B"] = false, ["Zeta"] = 1, ["a1"] = 4, ["a_b"] = 3, ["alpha"] = 2, ["bounty"] = "Duhpope Mon:1", ["on"] = true, ["sig"] = "137fFOGvi6BRkJNEC/QSO/aSyWeexMHuUawEb6SNTZOF0i3YSNqeg/FVYJy1bHBhVKnUs/ICCajSmTiC1Qv1I+8/VRhcGBg" } },
		{ kind = "claim", id = "Duhpope Mon:6", origin = "Duhpope Mon", seq = 6, prev = "0b513e65", t = 1790370185, hash = "f7b14d50", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM",
			data = { ["big"] = 1000000000000000.0, ["bounty"] = "Duhpope Mon:1", ["death"] = "Gankalot-Realm:812", ["long"] = 123456789012345.0, ["neg"] = -3.25, ["sig"] = "137fFOGvilv0voPEUxZUoWFi3wT+rfXWCHYjxUY+JowQgVDnyT4uNcadmmZTot1bNpqs/4ZIgKw7YwoS2NfajFbmupKAcAg", ["tiny"] = 1.4999999999999999e-07, ["x"] = 0.10000000000000001 } },
		{ kind = "confirm", id = "Duhpope Mon:7", origin = "Duhpope Mon", seq = 7, prev = "f7b14d50", t = 1790370222, hash = "aac5376d", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM",
			data = { ["claim"] = "Hunterman-Realm:4021", ["sig"] = "137fFOGvidbz9pT/6Kh2kzwxMMQK59mapCFWszpXahBEWQfMGqa5ZOj14cRzp2oybqx6+BdbFgtJsqRMVoMsTSvwrpffDDQ" } },
		{ kind = "mark", id = "Duhpope Mon:8", origin = "Duhpope Mon", seq = 8, prev = "aac5376d", t = 1790370259, hash = "2508402a", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM",
			data = { ["claim"] = "Hunterman-Realm:4021", ["disputed"] = true, ["sig"] = "137fFOGviHPCqtEBUAgxq+5bKsDQW173yDWzlqs6nd5NdmE0nUjhBIB3zhhsoUs41N69F005uhP/FY2sii+yIszPko2eeDg", ["why"] = "no kill seen" } },
		{ kind = "payment", id = "Duhpope Mon:9", origin = "Duhpope Mon", seq = 9, prev = "2508402a", t = 1790370296, hash = "f63b4998", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM",
			data = { ["amount"] = 1500000, ["bounty"] = "Duhpope Mon:1", ["claim"] = "Hunterman-Realm:4021", ["side"] = "payer", ["sig"] = "137fFOGvi13MKtn1elIMGC1PVac84W/u2u9KlLsKb7EV78TdAiYrHlGueNAUWbf3x9NGf0WkRnKa+wOnwEFvy7k3Ox2YmDw", ["to"] = "Hunterman" } },
		{ kind = "link", id = "Duhpope Mon:10", origin = "Duhpope Mon", seq = 10, prev = "f63b4998", t = 1790370333, hash = "c4cd37fd", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM",
			data = { ["code"] = "ABCD2345", ["guid"] = "Player-4613-00ABCDEF", ["sig"] = "137fFOGvidqtzIrKmI4EiuZrHXJqHp8YKMcmk1LkQYBTOlgXpeYlhHVz9BcBJj/Fpjfp7GtDrvSjHWtFVLpjt/GbiZCk+BA" } },
		{ kind = "notice", id = "Duhpope Mon:11", origin = "Duhpope Mon", seq = 11, prev = "c4cd37fd", t = 1790370370, hash = "626b4c39", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM",
			data = { ["amount"] = 7500, ["bounty"] = "Ally Guy:9", ["poster"] = "0badf00d", ["sig"] = "137fFOGviraSf+6COaVWSr+XtEXXzG9Wx8iAAs1niJqTsMXMsDdzD87h84wf0C33W8s2S6+zK4NoTjAqUCVMcQGGZnRFkDQ", ["target"] = "Player-4613-00FB062B", ["targetName"] = "Khal Drogash" } },
		{ kind = "mark", id = "Duhpope Mon:12", origin = "Duhpope Mon", seq = 12, prev = "626b4c39", t = 1790370407, hash = "80064d41", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM",
			data = { ["claim"] = "Hunterman-Realm:4021", ["flag"] = true, ["flagText"] = "true", ["k=v"] = "=", ["n"] = 100, ["nText"] = "100", ["note"] = "Evil\
pq=1", ["path"] = "C:\\Wanted\\n", ["sig"] = "137fFOGviihd8WvtRgvtLQk5H8r7Ks+D/8rF4CwN264oHTy+oe3HOSMObL7Zne0h89PD9s4F94NdsEKyGqO5g6qiYjzgSBA" } },
		{ kind = "pass", id = "Duhpope Mon:13", origin = "Duhpope Mon", seq = 13, prev = "80064d41", t = 1790370444, hash = "747242cb", pk = "jCWDY8Sy2JXoYIGJomvT+hnBLgzDv5/Yl3uORNL0tdM",
			data = { ["bounty"] = "Duhpope Mon:1", ["eq=="] = "==", ["f"] = false, ["multi"] = "a\
\
b", ["sig"] = "137fFOGvirjrw6eraSzZDPMztwnn587LEWyxXjSiaEs8I4LBZ5q3shtYsGARhad0+zfEWGTcTv8JCaXIiJ+0VZcRuWGrCCg", ["to"] = "Back\\Slash", ["zero"] = 0 } },
		{ kind = "bounty", id = "Lua Fixture:1", origin = "Lua Fixture", seq = 1, prev = "0", t = 1790380060, hash = "57315011", pk = "eG5/N/0inyG/ZzWArEoBVhzjmHMHtxkfBE/g6Y0RgwI",
			data = { ["amount"] = 250000, ["level"] = 25, ["sig"] = "1S7NmBAw2DqKb+cwOugV9axECsztK0QGy5hGllYu+5j+TynOLwvh3qlrFScu5IncMNcL0s4a+K8bHmVmta8Ks27UEO9NBAQ", ["target"] = "Player-4395-00C0FFEE", ["targetName"] = "Grünwald Ødegård", ["x"] = 45.25, ["y"] = 61.5, ["zone"] = "Ashenvale" } },
		{ kind = "claim", id = "Lua Fixture:2", origin = "Lua Fixture", seq = 2, prev = "57315011", t = 1790380120, hash = "bf595970", pk = "eG5/N/0inyG/ZzWArEoBVhzjmHMHtxkfBE/g6Y0RgwI",
			data = { ["bounty"] = "Lua Fixture:1", ["kill"] = "Hunter Two:77", ["killT"] = 1790380100, ["sig"] = "1S7NmBAw2DZYZsIoLCPV3aIFOjycOn4yrm396Xq3boDRyzer1ObAkny4tKgmIyA17JVl7lZuT0bN5u5G8pcGlmx6IgczTAQ", ["victim"] = "Player-4395-00C0FFEE", ["victimName"] = "Grünwald Ødegård", ["zone"] = "Ashenvale" } },
		{ kind = "confirm", id = "Lua Fixture:3", origin = "Lua Fixture", seq = 3, prev = "bf595970", t = 1790380180, hash = "07533805", pk = "eG5/N/0inyG/ZzWArEoBVhzjmHMHtxkfBE/g6Y0RgwI",
			data = { ["claim"] = "Hunter Two:78", ["disputed"] = true, ["sig"] = "1S7NmBAw2Wk8bV700ic5IAv+vuq0qINgD5ha3cTV4IBVTsc9CtEvCqxhpB7/QY2m7EErpMNvhdHLTv9LR08jPHJRI8CzrDw" } },
		{ kind = "mark", id = "Lua Fixture:4", origin = "Lua Fixture", seq = 4, prev = "07533805", t = 1790380240, hash = "22b04416", pk = "eG5/N/0inyG/ZzWArEoBVhzjmHMHtxkfBE/g6Y0RgwI",
			data = { ["about"] = "Hunter Two", ["category"] = "disputed claim", ["evidence"] = "Hunter Two:78", ["sig"] = "1S7NmBAw2pwVcobFmkz/k5yHWjiNd90+TXThu+uaOUQ4rGsfoRujVvlJ9AbyMIkskcbpHG8CRwQyMhSQHwjVEanWa0bhuBg" } },
		{ kind = "payment", id = "Lua Fixture:5", origin = "Lua Fixture", seq = 5, prev = "22b04416", t = 1790380300, hash = "6be747bb", pk = "eG5/N/0inyG/ZzWArEoBVhzjmHMHtxkfBE/g6Y0RgwI",
			data = { ["amount"] = 250000, ["bounty"] = "Lua Fixture:1", ["claim"] = "Hunter Two:78", ["from"] = "Poster Three", ["side"] = "payee", ["sig"] = "1S7NmBAw2XORFBwF15a0JcjY2lrMjQE3OmvnI8px1TJhfm8FRLNPNQa65FSdwAB9emi25460lvYMK4SUD8MH6FjUBjXkGAw" } },
		{ kind = "notice", id = "Lua Fixture:6", origin = "Lua Fixture", seq = 6, prev = "6be747bb", t = 1790380360, hash = "5db84dee", pk = "eG5/N/0inyG/ZzWArEoBVhzjmHMHtxkfBE/g6Y0RgwI",
			data = { ["amount"] = 2147483647, ["bounty"] = "w1a2b3c4d", ["postedAt"] = 1790379000, ["sig"] = "1S7NmBAw2zeUQUlq/iAoGXmrPtRFZDshfBCdc5u3bFa3kxDunwZtdhjgqogfz3uL9SW85RylZzKLLitVVWezm4ZEsMIZhCg", ["target"] = "Player-1-0000BEEF", ["targetName"] = "Nameless" } },
	},
}
