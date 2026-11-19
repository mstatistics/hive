<script lang="ts">
	import { ListItem, Icon } from 'm3-svelte';
	import iconScience from '@ktibow/iconset-material-symbols/science';
	import iconDevicesOther from '@ktibow/iconset-material-symbols/devices-other';
	import iconArrowForward from '@ktibow/iconset-material-symbols/arrow-forward';
	import { trials, experiments, devices } from '#lib/mock';
</script>

<div class="page">
	<h1 class="page-title">Home</h1>

	<!-- Trials -->
	<section class="section">
		<h2 class="section-heading">Recent Trials</h2>
		<div class="trials-scroll">
			{#each trials.slice(0, 8) as trial (trial.id)}
				<a class="trial-card" href="/experiments/{trial.experimentId}/trials/{trial.id}">
					<div class="trial-art">
						{#if trial.thumbnail}
							<img src={trial.thumbnail} alt={trial.name} />
						{/if}
					</div>
					<div class="trial-info">
						<p class="trial-name">{trial.name}</p>
						<p class="trial-sub">{trial.experimentName}</p>
						<p class="trial-sub">{trial.deviceName}</p>
					</div>
				</a>
			{/each}
		</div>
	</section>

	<!-- Experiments preview -->
	<section class="section">
		<a class="section-heading-link" href="/experiments">
			<h2 class="section-heading">Experiments</h2>
			<Icon style="margin-left: 0.25rem;" icon={iconArrowForward}/>
		</a>
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
		<a class="section-heading-link" href="/devices">
			<h2 class="section-heading">Devices</h2>
			<Icon style="margin-left: 0.25rem;" icon={iconArrowForward}/>
		</a>
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
		width: 100%;
	}

	.page-title {
		@apply --m3-display-small;
		margin: 0 0 2rem;
	}

	.section {
		margin-bottom: 2.5rem;
	}

	.section-heading-link {
		display: inline-flex;
		align-items: center;
		gap: 0.25rem;
		margin-bottom: 0.75rem;
		text-decoration: none;
		color: var(--m3c-on-surface);
	}

	.section-heading-link:hover {
		color: var(--m3c-primary);
	}

	.section-heading {
		@apply --m3-title-large;
		margin: 0 0 0.75rem;
	}

	.section-heading-link .section-heading {
		margin-bottom: 0;
	}

	/* Trials carousel */
	.trials-scroll {
		display: flex;
		gap: 1rem;
		overflow-x: auto;
		padding-bottom: 0.5rem;
		scrollbar-width: none;
	}

	.trials-scroll::-webkit-scrollbar {
		display: none;
	}

	.trial-card {
		display: flex;
		flex-direction: column;
		gap: 0.625rem;
		flex-shrink: 0;
		width: 260px;
		text-decoration: none;
		color: var(--m3c-on-surface);
	}

	.trial-art {
		width: 260px;
		height: 170px;
		border-radius: 16px;
		background: var(--m3c-surface-container-highest);
		overflow: hidden;
		flex-shrink: 0;
	}

	.trial-art img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.trial-info {
		display: flex;
		flex-direction: column;
		gap: 0.1rem;
		padding-inline: 0.125rem;
	}

	.trial-name {
		@apply --m3-body-medium;
		font-weight: 600;
		margin: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.trial-sub {
		@apply --m3-body-small;
		margin: 0;
		color: var(--m3c-on-surface-variant);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
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
