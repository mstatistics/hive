<script lang="ts">
	import { NavigationRail, NavigationRailItem, Button, Icon } from 'm3-svelte';
	import { page } from '$app/state';
	import type { LayoutProps } from './$types';
	import '../app.css';

	import iconHome from '@ktibow/iconset-material-symbols/home';
	import iconScience from '@ktibow/iconset-material-symbols/science';
	import iconDevicesOther from '@ktibow/iconset-material-symbols/devices-other';
	import iconPerson from '@ktibow/iconset-material-symbols/person';
	import iconSettings from '@ktibow/iconset-material-symbols/settings';
	import iconSwitchAccount from '@ktibow/iconset-material-symbols/switch-account';
	// import favicon from '$lib/assets/favicon.svg';
	import { currentOrg } from '#lib/mock';

	let { children }: LayoutProps = $props();

	let railOpen = $state(false);
	const path = $derived(page.url.pathname);
</script>

<svelte:head>
	<title>Hive · Greenhouse</title>
	<!-- <link rel="icon" href={favicon} /> -->
</svelte:head>

<div class="app-shell">
	<NavigationRail collapse bind:open={railOpen}>
		{#snippet fab(isOpen)}
			{#if isOpen}
				<div class="org-panel">
					<div class="org-initials">{currentOrg.initials}</div>
					<div class="org-info">
						<span class="org-name">{currentOrg.name}</span>
						<div class="org-actions">
							<Button variant="text" iconType="full" onclick={() => {}}>
								<Icon icon={iconSettings} />
							</Button>
							<Button variant="text" iconType="full" onclick={() => {}}>
								<Icon icon={iconSwitchAccount} />
							</Button>
						</div>
					</div>
				</div>
			{:else}
				<div class="org-badge">{currentOrg.initials}</div>
			{/if}
		{/snippet}

		<NavigationRailItem label="Home" icon={iconHome} active={path === '/'} href="/" />
		<NavigationRailItem
			label="Experiments"
			icon={iconScience}
			active={path.startsWith('/experiments')}
			href="/experiments"
		/>
		<NavigationRailItem
			label="Devices"
			icon={iconDevicesOther}
			active={path.startsWith('/devices')}
			href="/devices"
		/>

		<NavigationRailItem label="Account" icon={iconPerson} active={false} href="/account" />
	</NavigationRail>

	<main class="main-content">
		{@render children()}
	</main>
</div>

<style>
	.app-shell {
		display: flex;
		height: 100dvh;
		overflow: hidden;
		background: var(--m3c-surface-container);
	}

	.main-content {
		flex: 1;
		overflow-y: auto;
		padding: 2rem 2.5rem;
		background: var(--m3c-surface);
	}

	/* Hide scrollbar on the navigation rail */
	:global(.app-shell > .m3-container .rail) {
		scrollbar-width: none;
	}

	:global(.app-shell > .m3-container .rail::-webkit-scrollbar) {
		display: none;
	}

	/* Org panel (rail expanded) */
	.org-panel {
		display: flex;
		align-items: flex-start;
		gap: 0.75rem;
		padding-block: 0.75rem;
	}

	.org-initials {
		width: 2.25rem;
		height: 2.25rem;
		border-radius: 50%;
		background-color: var(--m3c-primary-container);
		color: var(--m3c-on-primary-container);
		display: flex;
		align-items: center;
		justify-content: center;
		font-weight: 600;
		font-size: 0.8rem;
		flex-shrink: 0;
	}

	.org-info {
		display: flex;
		flex-direction: column;
		gap: 0.25rem;
		min-width: 0;
	}

	.org-name {
		@apply --m3-label-large;
		color: var(--m3c-on-surface);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.org-actions {
		display: flex;
		gap: 0.125rem;
		margin-inline-start: -0.5rem;
	}

	/* Org badge (rail collapsed) */
	.org-badge {
		width: 2.25rem;
		height: 2.25rem;
		border-radius: 50%;
		background-color: var(--m3c-primary-container);
		color: var(--m3c-on-primary-container);
		display: flex;
		align-items: center;
		justify-content: center;
		font-weight: 600;
		font-size: 0.8rem;
		margin: 0.5rem auto;
	}
</style>
