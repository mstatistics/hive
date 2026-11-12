<script lang="ts">
	import { Card, ListItem, Button, Icon } from 'm3-svelte';
	import iconScience from '@ktibow/iconset-material-symbols/science';
	import iconDevicesOther from '@ktibow/iconset-material-symbols/devices-other';
	import { trials, experiments, devices } from '#lib/mock';

	const STATUS_LABEL: Record<string, string> = {
		active: 'Active',
		paused: 'Paused',
		completed: 'Done'
	};
</script>

<div class="page">
	<h1 class="page-title">Home</h1>

	<!-- Trials -->
	<section class="section">
		<h2 class="section-heading">Recent Trials</h2>
		<div class="trials-scroll">
			{#each trials as trial (trial.id)}
				<div class="trial-wrap">
					<Card variant="elevated">
						<div class="trial-body">
							<div class="trial-top">
								<span class="status-pill" data-status={trial.status}>
									{STATUS_LABEL[trial.status]}
								</span>
								<span class="trial-days">Day {trial.daysElapsed}</span>
							</div>
							<p class="trial-name">{trial.name}</p>
							<p class="trial-meta">{trial.recipeName}</p>
							<p class="trial-meta">{trial.deviceName}</p>
						</div>
					</Card>
				</div>
			{/each}
		</div>
	</section>

	<!-- Experiments preview -->
	<section class="section">
		<div class="section-header">
			<h2 class="section-heading">Experiments</h2>
			<Button variant="tonal" href="/experiments">View all</Button>
		</div>
		<div class="list-container">
			{#each experiments.slice(0, 3) as exp (exp.id)}
				<ListItem
					headline={exp.name}
					supporting="{exp.trialCount} trials · Updated {exp.lastUpdated}"
					href="/experiments"
				>
					{#snippet leading()}
						<Icon icon={iconScience} />
					{/snippet}
				</ListItem>
			{/each}
		</div>
	</section>

	<!-- Devices preview -->
	<section class="section">
		<div class="section-header">
			<h2 class="section-heading">Devices</h2>
			<Button variant="tonal" href="/devices">View all</Button>
		</div>
		<div class="list-container">
			{#each devices.slice(0, 3) as device (device.id)}
				<ListItem headline={device.name} supporting={device.model} href="/devices">
					{#snippet leading()}
						<Icon icon={iconDevicesOther} />
					{/snippet}
					{#snippet trailing()}
						<span class="status-dot" data-online={device.status === 'online'}>
							{device.status === 'online' ? 'Online' : 'Offline'}
						</span>
					{/snippet}
				</ListItem>
			{/each}
		</div>
	</section>
</div>

<style>
	.page {
		max-width: 900px;
	}

	.page-title {
		@apply --m3-display-small;
		margin: 0 0 2rem;
	}

	.section {
		margin-bottom: 2.5rem;
	}

	.section-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		margin-bottom: 0.75rem;
	}

	.section-heading {
		@apply --m3-title-large;
		margin: 0 0 0.75rem;
	}

	.section-header .section-heading {
		margin-bottom: 0;
	}

	/* Trials scroll */
	.trials-scroll {
		display: flex;
		gap: 1rem;
		overflow-x: auto;
		padding-bottom: 0.75rem;
		scroll-snap-type: x mandatory;
		scrollbar-width: thin;
		scrollbar-color: var(--m3c-outline-variant) transparent;
	}

	.trial-wrap {
		min-width: 220px;
		max-width: 260px;
		flex-shrink: 0;
		scroll-snap-align: start;
	}

	.trial-body {
		padding: 1rem;
		display: flex;
		flex-direction: column;
		gap: 0.25rem;
	}

	.trial-top {
		display: flex;
		justify-content: space-between;
		align-items: center;
		margin-bottom: 0.5rem;
	}

	.trial-name {
		@apply --m3-title-medium;
		margin: 0;
	}

	.trial-meta {
		@apply --m3-body-small;
		color: var(--m3c-on-surface-variant);
		margin: 0;
	}

	.trial-days {
		@apply --m3-label-small;
		color: var(--m3c-on-surface-variant);
	}

	.status-pill {
		@apply --m3-label-small;
		padding: 0.15rem 0.6rem;
		border-radius: 999px;
		font-weight: 600;
	}

	.status-pill[data-status='active'] {
		background: var(--m3c-primary-container);
		color: var(--m3c-on-primary-container);
	}

	.status-pill[data-status='paused'] {
		background: var(--m3c-tertiary-container);
		color: var(--m3c-on-tertiary-container);
	}

	.status-pill[data-status='completed'] {
		background: var(--m3c-secondary-container);
		color: var(--m3c-on-secondary-container);
	}

	/* Lists */
	.list-container {
		border-radius: 12px;
		overflow: hidden;
		background-color: var(--m3c-surface-container-low);
	}

	.status-dot {
		@apply --m3-label-small;
		padding: 0.15rem 0.6rem;
		border-radius: 999px;
		font-weight: 600;
		white-space: nowrap;
	}

	.status-dot[data-online='true'] {
		background: var(--m3c-primary-container);
		color: var(--m3c-on-primary-container);
	}

	.status-dot[data-online='false'] {
		background: var(--m3c-error-container);
		color: var(--m3c-on-error-container);
	}
</style>
