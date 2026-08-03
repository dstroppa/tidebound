--!strict
-- Tidebound Biome Configuration
-- Runtime lighting, water, fog, and post-processing presets for MVP biomes.
-- Reference: GDD Sections 3 (biome descriptions) and 7 (Creative Direction).

local Types = require(script.Types)

type Biome = Types.Biome

type LightingConfig = {
	clockTime: number,
	brightness: number,
	ambient: Color3,
	outdoorAmbient: Color3,
	colorShift_Top: Color3,
	colorShift_Bottom: Color3,
	shadowSoftness: number,
}

type ColorCorrectionConfig = {
	saturation: number,
	tintColor: Color3,
	brightness: number,
	contrast: number,
}

type WaterConfig = {
	waterColor: Color3,
	underwaterColor: Color3,
	waterReflectance: number,
	waterTransparency: number,
	waterWaveSize: number,
	waterWaveSpeed: number,
}

type FogConfig = {
	fogColor: Color3,
	fogStart: number,
	fogEnd: number,
}

type PostProcessingConfig = {
	bloomIntensity: number,
	bloomThreshold: number,
	sunRays: boolean,
}

export type BiomeConfig = {
	biome: Biome,
	displayName: string,
	unlockLevel: number,
	lighting: LightingConfig,
	colorCorrection: ColorCorrectionConfig,
	water: WaterConfig,
	fog: FogConfig,
	postProcessing: PostProcessingConfig,
	defaultTimeOfDay: Types.TimeOfDay,
	defaultWeather: Types.Weather,
}

local BIOME_CONFIG: { [Biome]: BiomeConfig } = {
	coral_shallows = {
		biome = "coral_shallows",
		displayName = "Coral Shallows",
		unlockLevel = 1,
		lighting = {
			clockTime = 14,
			brightness = 3,
			ambient = Color3.fromHex("FFD700"):Lerp(Color3.fromHex("FFFFFF"), 0.3),
			outdoorAmbient = Color3.fromHex("87CEEB"),
			colorShift_Top = Color3.fromHex("FFD700"),
			colorShift_Bottom = Color3.fromHex("4ECDC4"),
			shadowSoftness = 0.4,
		},
		colorCorrection = {
			saturation = 0.1,
			tintColor = Color3.fromHex("FFECD2"),
			brightness = 0.05,
			contrast = 0.05,
		},
		water = {
			waterColor = Color3.fromHex("4ECDC4"),
			underwaterColor = Color3.fromHex("44B3AA"),
			waterReflectance = 0.4,
			waterTransparency = 0.1,
			waterWaveSize = 0.3,
			waterWaveSpeed = 12,
		},
		fog = {
			fogColor = Color3.fromHex("87CEEB"),
			fogStart = 500,
			fogEnd = 5000,
		},
		postProcessing = {
			bloomIntensity = 0.4,
			bloomThreshold = 0.9,
			sunRays = true,
		},
		defaultTimeOfDay = "day",
		defaultWeather = "clear",
	},

	mangrove_marsh = {
		biome = "mangrove_marsh",
		displayName = "Mangrove Marsh",
		unlockLevel = 5,
		lighting = {
			clockTime = 11,
			brightness = 1.5,
			ambient = Color3.fromHex("8E9AAF"),
			outdoorAmbient = Color3.fromHex("A3B5A6"),
			colorShift_Top = Color3.fromHex("8E9AAF"),
			colorShift_Bottom = Color3.fromHex("6B7B3A"),
			shadowSoftness = 0.8,
		},
		colorCorrection = {
			saturation = -0.15,
			tintColor = Color3.fromHex("C4D0C3"),
			brightness = -0.05,
			contrast = 0.02,
		},
		water = {
			waterColor = Color3.fromHex("6B7B3A"),
			underwaterColor = Color3.fromHex("4A5A23"),
			waterReflectance = 0.15,
			waterTransparency = 0.35,
			waterWaveSize = 0.12,
			waterWaveSpeed = 4,
		},
		fog = {
			fogColor = Color3.fromHex("A3B5A6"),
			fogStart = 50,
			fogEnd = 300,
		},
		postProcessing = {
			bloomIntensity = 0.1,
			bloomThreshold = 1,
			sunRays = false,
		},
		defaultTimeOfDay = "day",
		defaultWeather = "foggy",
	},

	kelp_forest = {
		biome = "kelp_forest",
		displayName = "Kelp Forest",
		unlockLevel = 12,
		lighting = {
			clockTime = 13,
			brightness = 2,
			ambient = Color3.fromHex("1A3C40"),
			outdoorAmbient = Color3.fromHex("87CECB"),
			colorShift_Top = Color3.fromHex("FFF8DC"),
			colorShift_Bottom = Color3.fromHex("1A3C40"),
			shadowSoftness = 0.65,
		},
		colorCorrection = {
			saturation = 0.05,
			tintColor = Color3.fromHex("C9E8D0"),
			brightness = -0.02,
			contrast = 0.08,
		},
		water = {
			waterColor = Color3.fromHex("2E86AB"),
			underwaterColor = Color3.fromHex("1B6B8A"),
			waterReflectance = 0.3,
			waterTransparency = 0.2,
			waterWaveSize = 0.25,
			waterWaveSpeed = 8,
		},
		fog = {
			fogColor = Color3.fromHex("1A3C40"),
			fogStart = 150,
			fogEnd = 1200,
		},
		postProcessing = {
			bloomIntensity = 0.3,
			bloomThreshold = 0.8,
			sunRays = true,
		},
		defaultTimeOfDay = "day",
		defaultWeather = "clear",
	},
}

return BIOME_CONFIG
