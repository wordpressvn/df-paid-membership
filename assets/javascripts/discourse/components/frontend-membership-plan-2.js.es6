export default Ember.Component.extend({
	_didInsertElement: function() {
		// Вызывается после вызова всех init для всех компонентов.
		const color = '#' + this.get('plan').get('color');
		this.$().css({'border-color': color});
	}.on('didInsertElement')
});