<script lang="ts">
	import { ListItem, Icon } from 'm3-svelte';
	import iconScience from '@ktibow/iconset-material-symbols/science';
	import iconChevronRight from '@ktibow/iconset-material-symbols/chevron-right';
	import { experiments } from '#lib/mock';
</script>

<div class="page">
	<h1 class="page-title">Experiments</h1>

	<div class="list-container">
		{#each experiments as exp (exp.id)}
			<ListItem headline={exp.name} supporting={exp.description} href="/experiments/{exp.id}">
				{#snippet leading()}
					<Icon icon={iconScience} />
				{/snippet}
				{#snippet trailing()}
					<div class="meta-trailing">
						<span class="trial-badge">{exp.trialCount} trials</span>
						<Icon icon={iconChevronRight} />
					</div>
				{/snippet}
			</ListItem>
		{/each}
	</div>
</div>

<style>
	.page {
		width: 100%;
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

	.meta-trailing {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		color: var(--m3c-on-surface-variant);
	}

	.trial-badge {
		@apply --m3-label-medium;
		color: var(--m3c-primary);
		white-space: nowrap;
	}
</style>
