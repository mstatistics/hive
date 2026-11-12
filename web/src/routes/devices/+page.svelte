<script lang="ts">
	import { ListItem, Icon } from 'm3-svelte';
	import iconDevicesOther from '@ktibow/iconset-material-symbols/devices-other';
	import { devices } from '#lib/mock';

	function formatLastSeen(iso: string): string {
		return new Date(iso).toLocaleString('en-GB', { dateStyle: 'short', timeStyle: 'short' });
	}
</script>

<div class="page">
	<h1 class="page-title">Devices</h1>

	<div class="list-container">
		{#each devices as device (device.id)}
			<ListItem
				headline={device.name}
				supporting="{device.model} · Last seen {formatLastSeen(device.lastSeen)}"
				href="/devices/{device.id}"
			>
				{#snippet leading()}
					<Icon icon={iconDevicesOther} />
				{/snippet}
				{#snippet trailing()}
					<span class="status-pill" data-online={device.status === 'online'}>
						{device.status === 'online' ? 'Online' : 'Offline'}
					</span>
				{/snippet}
			</ListItem>
		{/each}
	</div>
</div>

<style>
	.page {
		max-width: 760px;
	}

	.page-title {
		@apply --m3-display-small;
		margin: 0 0 2rem;
	}

	.list-container {
		border-radius: 12px;
		overflow: hidden;
		background-color: var(--m3c-surface-container-low);
	}

	.status-pill {
		@apply --m3-label-medium;
		padding: 0.2rem 0.6rem;
		border-radius: 999px;
		font-weight: 600;
		white-space: nowrap;
	}

	.status-pill[data-online='true'] {
		background: var(--m3c-primary-container);
		color: var(--m3c-on-primary-container);
	}

	.status-pill[data-online='false'] {
		background: var(--m3c-error-container);
		color: var(--m3c-on-error-container);
	}
</style>
