<template>
  <div class="restocking">
    <div class="page-header">
      <h2>Restocking</h2>
      <p>AI-recommended restocking orders based on demand forecasts</p>
    </div>

    <div v-if="loading" class="loading">Loading forecasts...</div>
    <div v-else>
      <!-- Budget Slider -->
      <div class="card">
        <div class="budget-slider-row">
          <label class="budget-label" for="budget-slider">Available Budget</label>
          <span class="budget-display">{{ formatCurrency(budget) }}</span>
        </div>
        <input
          id="budget-slider"
          type="range"
          min="0"
          max="200000"
          step="5000"
          v-model.number="budget"
          class="budget-range"
        />
        <div class="budget-range-hints">
          <span>{{ currencySymbol }}0</span>
          <span>{{ currencySymbol }}200,000</span>
        </div>
      </div>

      <!-- Budget Meter -->
      <div class="card">
        <div class="meter-header">
          <span class="meter-label">Budget Usage</span>
          <span class="meter-text">
            {{ Math.round(budgetPercent) }}% of budget used &middot;
            {{ formatCurrency(totalCost) }} of {{ formatCurrency(budget) }}
          </span>
        </div>
        <div class="progress-track">
          <div
            class="progress-fill"
            :class="meterColorClass"
            :style="{ width: budgetPercent + '%' }"
          ></div>
        </div>
      </div>

      <!-- Recommendations Table -->
      <div class="card">
        <div class="card-header">
          <h3 class="card-title">Recommended Items</h3>
        </div>
        <div class="table-container">
          <table>
            <thead>
              <tr>
                <th>Item Name</th>
                <th>SKU</th>
                <th>Trend</th>
                <th>Qty to Order</th>
                <th>Unit Cost</th>
                <th>Total Cost</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="item in recommendations" :key="item.item_sku">
                <td>{{ item.item_name }}</td>
                <td><strong>{{ item.item_sku }}</strong></td>
                <td>
                  <span :class="['badge', item.trend]">{{ item.trend }}</span>
                </td>
                <td>{{ item.forecasted_demand }}</td>
                <td>{{ formatCurrency(item.unit_cost) }}</td>
                <td>{{ formatCurrency(item.totalCost) }}</td>
                <td>
                  <span v-if="item.included" class="badge success">Included</span>
                  <span v-else class="badge over-budget">Over Budget</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <!-- Table Footer -->
        <div class="table-footer">
          <span>{{ includedItems.length }} of {{ recommendations.length }} items</span>
          <span class="footer-total">Total: {{ formatCurrency(totalCost) }}</span>
        </div>
      </div>

      <!-- Place Order Button -->
      <div class="action-area">
        <button
          class="btn-primary"
          :disabled="includedItems.length === 0 || placing"
          @click="placeOrder"
        >
          {{ placing ? 'Placing Order...' : 'Place Restocking Order' }}
        </button>
        <div v-if="successMessage" class="success-banner">
          {{ successMessage }}
        </div>
      </div>
    </div>
  </div>
</template>

<script>
import { ref, computed, onMounted } from 'vue'
import { api } from '../api'
import { useI18n } from '../composables/useI18n'

// Priority order for greedy algorithm: increasing items first, then stable, then decreasing
const TREND_PRIORITY = { increasing: 0, stable: 1, decreasing: 2 }

export default {
  name: 'Restocking',
  setup() {
    const { t, currentCurrency } = useI18n()

    const allForecasts = ref([])
    const loading = ref(false)
    const placing = ref(false)
    const successMessage = ref('')
    const budget = ref(100000)

    const currencySymbol = computed(() => {
      return currentCurrency.value === 'JPY' ? '¥' : '$'
    })

    const formatCurrency = (value) => {
      return value.toLocaleString('en-US', {
        style: 'currency',
        currency: 'USD',
        maximumFractionDigits: 0
      })
    }

    // Greedy recommendation algorithm: sort by trend priority, include items while under budget
    const recommendations = computed(() => {
      const sorted = [...allForecasts.value].sort((a, b) => {
        const pa = TREND_PRIORITY[a.trend] ?? 99
        const pb = TREND_PRIORITY[b.trend] ?? 99
        return pa - pb
      })

      let runningTotal = 0
      return sorted.map(forecast => {
        const totalCost = forecast.forecasted_demand * forecast.unit_cost
        const canInclude = (runningTotal + totalCost) <= budget.value
        if (canInclude) {
          runningTotal += totalCost
        }
        return {
          ...forecast,
          totalCost,
          included: canInclude
        }
      })
    })

    const includedItems = computed(() => {
      return recommendations.value.filter(item => item.included)
    })

    const totalCost = computed(() => {
      return includedItems.value.reduce((sum, item) => sum + item.totalCost, 0)
    })

    // Clamp to 100 for display (overage shouldn't occur due to algorithm, but guard anyway)
    const budgetPercent = computed(() => {
      if (budget.value === 0) return 0
      return Math.min((totalCost.value / budget.value) * 100, 100)
    })

    const meterColorClass = computed(() => {
      const pct = budgetPercent.value
      if (pct >= 80) return 'meter-yellow'
      return 'meter-green'
    })

    const loadForecasts = async () => {
      loading.value = true
      try {
        allForecasts.value = await api.getDemandForecasts()
      } catch (err) {
        console.error('Failed to load demand forecasts:', err)
      } finally {
        loading.value = false
      }
    }

    const placeOrder = async () => {
      placing.value = true
      successMessage.value = ''
      try {
        const orderItems = includedItems.value.map(f => ({
          sku: f.item_sku,
          name: f.item_name,
          quantity: f.forecasted_demand,
          unit_cost: f.unit_cost
        }))
        const order = await api.createRestockOrder({ items: orderItems })
        successMessage.value = `Restocking order ${order.id} placed successfully`
        budget.value = 100000
      } catch (err) {
        console.error('Failed to place restock order:', err)
      } finally {
        placing.value = false
      }
    }

    onMounted(loadForecasts)

    return {
      t,
      allForecasts,
      loading,
      placing,
      successMessage,
      budget,
      currencySymbol,
      formatCurrency,
      recommendations,
      includedItems,
      totalCost,
      budgetPercent,
      meterColorClass,
      placeOrder
    }
  }
}
</script>

<style scoped>
.restocking {
  /* Inherits .main-content padding from App.vue */
}

/* Budget Slider Card */
.budget-slider-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.75rem;
}

.budget-label {
  font-size: 0.875rem;
  font-weight: 600;
  color: #475569;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.budget-display {
  font-size: 1.5rem;
  font-weight: 700;
  color: #0f172a;
  letter-spacing: -0.025em;
}

.budget-range {
  width: 100%;
  height: 6px;
  accent-color: #2563eb;
  cursor: pointer;
  margin-bottom: 0.375rem;
}

.budget-range-hints {
  display: flex;
  justify-content: space-between;
  font-size: 0.75rem;
  color: #94a3b8;
}

/* Budget Meter Card */
.meter-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.75rem;
}

.meter-label {
  font-size: 0.875rem;
  font-weight: 600;
  color: #475569;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.meter-text {
  font-size: 0.875rem;
  color: #64748b;
}

.progress-track {
  width: 100%;
  height: 10px;
  background: #e2e8f0;
  border-radius: 999px;
  overflow: hidden;
}

.progress-fill {
  height: 100%;
  border-radius: 999px;
  transition: width 0.3s ease, background-color 0.3s ease;
}

.progress-fill.meter-green {
  background: #10b981;
}

.progress-fill.meter-yellow {
  background: #f59e0b;
}

/* Table Footer */
.table-footer {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.625rem 0.75rem;
  border-top: 1px solid #e2e8f0;
  background: #f8fafc;
  font-size: 0.875rem;
  color: #64748b;
  font-weight: 500;
  border-radius: 0 0 8px 8px;
}

.footer-total {
  font-weight: 700;
  color: #0f172a;
}

/* Over Budget badge — scoped gray style */
.badge.over-budget {
  background: #e2e8f0;
  color: #475569;
}

/* Action Area */
.action-area {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.75rem;
  margin-bottom: 1.5rem;
}

.btn-primary {
  padding: 0.625rem 1.5rem;
  background: #2563eb;
  color: #ffffff;
  border: none;
  border-radius: 8px;
  font-size: 0.938rem;
  font-weight: 600;
  cursor: pointer;
  transition: background 0.2s ease, opacity 0.2s ease;
}

.btn-primary:hover:not(:disabled) {
  background: #1d4ed8;
}

.btn-primary:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.success-banner {
  padding: 0.75rem 1.25rem;
  background: #d1fae5;
  color: #065f46;
  border: 1px solid #6ee7b7;
  border-radius: 8px;
  font-size: 0.938rem;
  font-weight: 500;
}
</style>
