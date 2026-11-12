export type TrialStatus = 'active' | 'completed' | 'paused';
export type DeviceStatus = 'online' | 'offline';

export interface Trial {
	id: string;
	name: string;
	recipeName: string;
	deviceName: string;
	startDate: string;
	status: TrialStatus;
	daysElapsed: number;
}

export interface Experiment {
	id: string;
	name: string;
	description: string;
	trialCount: number;
	lastUpdated: string;
}

export interface Device {
	id: string;
	name: string;
	model: string;
	status: DeviceStatus;
	lastSeen: string;
}

export const currentOrg = {
	name: 'Hive Research Lab',
	initials: 'HR'
};

export const trials: Trial[] = [
	{
		id: 't1',
		name: 'Basil Batch 7',
		recipeName: 'Mediterranean Herbs v2',
		deviceName: 'Chamber Alpha',
		startDate: '2026-10-01',
		status: 'active',
		daysElapsed: 42
	},
	{
		id: 't2',
		name: 'Tomato Trial 3',
		recipeName: 'High-Yield Tomato',
		deviceName: 'Chamber Beta',
		startDate: '2026-09-15',
		status: 'active',
		daysElapsed: 58
	},
	{
		id: 't3',
		name: 'Spinach Cycle 2',
		recipeName: 'Leafy Green Standard',
		deviceName: 'Chamber Gamma',
		startDate: '2026-10-20',
		status: 'paused',
		daysElapsed: 23
	},
	{
		id: 't4',
		name: 'Lettuce Mix A',
		recipeName: 'Baby Greens Accelerated',
		deviceName: 'Chamber Delta',
		startDate: '2026-09-01',
		status: 'completed',
		daysElapsed: 90
	},
	{
		id: 't5',
		name: 'Microgreens Run 5',
		recipeName: 'Fast Track Microgreens',
		deviceName: 'Chamber Alpha',
		startDate: '2026-11-01',
		status: 'active',
		daysElapsed: 11
	}
];

export const experiments: Experiment[] = [
	{
		id: 'e1',
		name: 'Mediterranean Herbs',
		description: 'Optimising basil and oregano growth under variable LED spectra.',
		trialCount: 7,
		lastUpdated: '2026-11-10'
	},
	{
		id: 'e2',
		name: 'High-Yield Tomato',
		description: 'Nutrient and CO₂ scheduling for maximum tomato fruit set.',
		trialCount: 3,
		lastUpdated: '2026-11-08'
	},
	{
		id: 'e3',
		name: 'Leafy Green Standard',
		description: 'Baseline growth recipe for fast-cycling leafy greens.',
		trialCount: 12,
		lastUpdated: '2026-10-30'
	},
	{
		id: 'e4',
		name: 'Baby Greens Accelerated',
		description: 'High-intensity short-cycle protocol for baby leaf production.',
		trialCount: 4,
		lastUpdated: '2026-10-15'
	},
	{
		id: 'e5',
		name: 'Fast Track Microgreens',
		description: 'Ultra-short cycle with high blue-light ratio for density.',
		trialCount: 5,
		lastUpdated: '2026-11-05'
	},
	{
		id: 'e6',
		name: 'Drought Stress Tolerance',
		description: 'Controlled deficit irrigation to improve secondary metabolite profiles.',
		trialCount: 2,
		lastUpdated: '2026-09-20'
	}
];

export const devices: Device[] = [
	{ id: 'd1', name: 'Chamber Alpha', model: 'GreenBox Pro 4000', status: 'online', lastSeen: '2026-11-12T10:34:00Z' },
	{ id: 'd2', name: 'Chamber Beta', model: 'GreenBox Pro 4000', status: 'online', lastSeen: '2026-11-12T10:33:45Z' },
	{ id: 'd3', name: 'Chamber Gamma', model: 'GreenBox Lite 2000', status: 'offline', lastSeen: '2026-11-11T18:22:00Z' },
	{ id: 'd4', name: 'Chamber Delta', model: 'GreenBox Pro 4000', status: 'online', lastSeen: '2026-11-12T10:30:00Z' },
	{ id: 'd5', name: 'Sensor Array 1', model: 'EnviroSense Hub', status: 'online', lastSeen: '2026-11-12T10:34:10Z' },
	{ id: 'd6', name: 'Irrigation Controller', model: 'HydroMaster v3', status: 'offline', lastSeen: '2026-11-10T09:00:00Z' }
];
