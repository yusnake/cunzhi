<script setup lang="ts">
import type { McpRequest } from '../../types/popup'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { useMessage } from 'naive-ui'
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'

import PopupActions from './PopupActions.vue'
import PopupContent from './PopupContent.vue'
import PopupInput from './PopupInput.vue'

interface AppConfig {
  theme: string
  window: {
    alwaysOnTop: boolean
    width: number
    height: number
    fixed: boolean
  }
  audio: {
    enabled: boolean
    url: string
  }
  reply: {
    enabled: boolean
    prompt: string
  }
}

interface Props {
  request: McpRequest | null
  appConfig: AppConfig
  mockMode?: boolean
  testMode?: boolean
}

interface Emits {
  response: [response: any]
  cancel: []
  themeChange: [theme: string]
  openMainLayout: []
  toggleAlwaysOnTop: []
  toggleAudioNotification: []
  updateAudioUrl: [url: string]
  testAudio: []
  stopAudio: []
  testAudioError: [error: any]
  updateWindowSize: [size: { width: number, height: number, fixed: boolean }]
}

const props = withDefaults(defineProps<Props>(), {
  mockMode: false,
  testMode: false,
})

const emit = defineEmits<Emits>()

// 使用消息提示
const message = useMessage()

// 响应式状态
const loading = ref(false)
const submitting = ref(false)
const selectedOptions = ref<string[]>([])
const userInput = ref('')
const draggedImages = ref<string[]>([])
const inputRef = ref()

// 继续回复配置
const continueReplyEnabled = ref(true)
const continuePrompt = ref('请按照最佳实践继续')

// 自动发送配置和状态
const autoSendEnabled = ref(false)
const autoSendTimeout = ref(60)
const autoSendMessage = ref('')
const countdown = ref(0)
const countdownTimer = ref<number | null>(null)
const lastInputTime = ref<number>(0) // 记录最后输入时间
const autoCancelled = ref(false) // 记录自动发送是否被取消

// 计算属性
const isVisible = computed(() => !!props.request)
const hasOptions = computed(() => (props.request?.predefined_options?.length ?? 0) > 0)
const canSubmit = computed(() => {
  if (hasOptions.value) {
    return selectedOptions.value.length > 0 || userInput.value.trim().length > 0 || draggedImages.value.length > 0
  }
  return userInput.value.trim().length > 0 || draggedImages.value.length > 0
})

// 获取输入组件的状态文本
const inputStatusText = computed(() => {
  return inputRef.value?.statusText || '等待输入...'
})

// 加载继续回复配置
async function loadReplyConfig() {
  try {
    const config = await invoke('get_reply_config')
    if (config) {
      const replyConfig = config as any
      continueReplyEnabled.value = replyConfig.enable_continue_reply ?? true
      continuePrompt.value = replyConfig.continue_prompt ?? '请按照最佳实践继续'

      // 加载自动发送配置
      autoSendEnabled.value = replyConfig.auto_send_enabled ?? false
      autoSendTimeout.value = replyConfig.auto_send_timeout ?? 60
      autoSendMessage.value = replyConfig.auto_send_message ?? ''
    }
  }
  catch (error) {
    console.log('加载继续回复配置失败，使用默认值:', error)
  }
}

// 启动倒计时
function startCountdown() {
  if (!autoSendEnabled.value) return

  countdown.value = autoSendTimeout.value
  countdownTimer.value = setInterval(() => {
    countdown.value--
    if (countdown.value <= 0) {
      autoSend()
    }
  }, 1000) as unknown as number
}

// 停止倒计时
function stopCountdown() {
  if (countdownTimer.value !== null) {
    clearInterval(countdownTimer.value)
    countdownTimer.value = null
  }
  countdown.value = 0
}

// 取消自动发送
function cancelAutoSend() {
  stopCountdown()
  autoCancelled.value = true
  message.info('已取消自动发送')
}

// 自动发送
async function autoSend() {
  stopCountdown()
  if (submitting.value) return

  // 检查用户是否正在输入（最近5秒内有输入活动）
  const now = Date.now()
  const isRecentlyTyping = (now - lastInputTime.value) < 5000

  if (isRecentlyTyping) {
    // 用户正在输入，延迟5秒后再次检查
    console.log('检测到用户正在输入，延迟5秒后再次检查')
    setTimeout(() => {
      // 5秒后再次检查
      checkAndAutoSend()
    }, 5000)
    return
  }

  // 立即执行自动发送
  await executeAutoSend()
}

// 检查并自动发送
async function checkAndAutoSend() {
  if (submitting.value) return

  // 检查输入框是否为空
  const hasUserInput = userInput.value.trim().length > 0
    || selectedOptions.value.length > 0
    || draggedImages.value.length > 0

  if (hasUserInput) {
    // 用户已经输入了内容，不自动发送，让用户自己决定
    console.log('检测到用户有输入，取消自动发送')
    autoCancelled.value = true
    message.info('检测到输入，已取消自动发送')
    return
  }

  // 输入框为空，执行自动发送
  await executeAutoSend()
}

// 执行自动发送
async function executeAutoSend() {
  if (submitting.value) return
  submitting.value = true

  try {
    // 只发送预设的自动发送消息
    const finalInput = autoSendMessage.value.trim() || '用户确认继续'

    // 直接构建响应，不通过 handleSubmit，避免触发条件性内容追加
    const response = {
      user_input: finalInput,
      selected_options: [],
      images: [],
      metadata: {
        timestamp: new Date().toISOString(),
        request_id: props.request?.id || null,
        source: 'popup_auto_send',
      },
    }

    if (props.mockMode) {
      await new Promise(resolve => setTimeout(resolve, 1000))
      message.success('自动发送成功')
    }
    else {
      await invoke('send_mcp_response', { response })
      await invoke('exit_app')
    }

    emit('response', response)
  }
  catch (error) {
    console.error('自动发送失败:', error)
    message.error('自动发送失败，请重试')
  }
  finally {
    submitting.value = false
  }
}

// 监听配置变化（当从设置页面切换回来时）
watch(() => props.appConfig.reply, (newReplyConfig) => {
  if (newReplyConfig) {
    continueReplyEnabled.value = newReplyConfig.enabled
    continuePrompt.value = newReplyConfig.prompt
  }
}, { deep: true, immediate: true })

// Telegram事件监听器
let telegramUnlisten: (() => void) | null = null

// 监听请求变化
watch(() => props.request, (newRequest) => {
  if (newRequest) {
    resetForm()
    autoCancelled.value = false // 重置取消状态
    loading.value = true
    // 每次显示弹窗时重新加载配置
    loadReplyConfig()
    setTimeout(() => {
      loading.value = false
      // 加载完成后启动倒计时
      startCountdown()
    }, 300)
  }
  else {
    // 弹窗关闭时停止倒计时
    stopCountdown()
  }
}, { immediate: true })

// 设置Telegram事件监听
async function setupTelegramListener() {
  try {
    telegramUnlisten = await listen('telegram-event', (event) => {
      console.log('🎯 [McpPopup] 收到Telegram事件:', event)
      console.log('🎯 [McpPopup] 事件payload:', event.payload)
      handleTelegramEvent(event.payload as any)
    })
    console.log('🎯 [McpPopup] Telegram事件监听器已设置')
  }
  catch (error) {
    console.error('🎯 [McpPopup] 设置Telegram事件监听器失败:', error)
  }
}

// 处理Telegram事件
function handleTelegramEvent(event: any) {
  console.log('🎯 [McpPopup] 开始处理事件:', event.type)

  switch (event.type) {
    case 'option_toggled':
      console.log('🎯 [McpPopup] 处理选项切换:', event.option)
      handleOptionToggle(event.option)
      break
    case 'text_updated':
      console.log('🎯 [McpPopup] 处理文本更新:', event.text)
      handleTextUpdate(event.text)
      break
    case 'continue_pressed':
      console.log('🎯 [McpPopup] 处理继续按钮')
      handleContinue()
      break
    case 'send_pressed':
      console.log('🎯 [McpPopup] 处理发送按钮')
      handleSubmit()
      break
    default:
      console.log('🎯 [McpPopup] 未知事件类型:', event.type)
  }
}

// 处理选项切换
function handleOptionToggle(option: string) {
  const index = selectedOptions.value.indexOf(option)
  if (index > -1) {
    // 取消选择
    selectedOptions.value.splice(index, 1)
  }
  else {
    // 添加选择
    selectedOptions.value.push(option)
  }

  // 同步到PopupInput组件
  if (inputRef.value) {
    inputRef.value.updateData({ selectedOptions: selectedOptions.value })
  }
}

// 处理选项复选框变化
function handleOptionChange(option: string, checked: boolean) {
  if (checked) {
    if (!selectedOptions.value.includes(option)) {
      selectedOptions.value.push(option)
    }
  }
  else {
    const idx = selectedOptions.value.indexOf(option)
    if (idx > -1) {
      selectedOptions.value.splice(idx, 1)
    }
  }

  // 同步到PopupInput组件
  if (inputRef.value) {
    inputRef.value.updateData({ selectedOptions: selectedOptions.value })
  }
}

// 处理文本更新
function handleTextUpdate(text: string) {
  userInput.value = text

  // 同步到PopupInput组件
  if (inputRef.value) {
    inputRef.value.updateData({ userInput: text })
  }
}

// 组件挂载时设置监听器和加载配置
onMounted(() => {
  loadReplyConfig()
  setupTelegramListener()
})

// 组件卸载时清理监听器
onUnmounted(() => {
  if (telegramUnlisten) {
    telegramUnlisten()
  }
  // 清理倒计时
  stopCountdown()
})

// 监听提交状态，提交时停止倒计时
watch(submitting, (isSubmitting) => {
  if (isSubmitting) {
    stopCountdown()
  }
})

// 重置表单
function resetForm() {
  selectedOptions.value = []
  userInput.value = ''
  draggedImages.value = []
  submitting.value = false
}

// 处理提交
async function handleSubmit() {
  if (!canSubmit.value || submitting.value)
    return

  submitting.value = true

  try {
    // 使用新的结构化数据格式
    const response = {
      user_input: userInput.value.trim() || null,
      selected_options: selectedOptions.value,
      images: draggedImages.value.map(imageData => ({
        data: imageData.split(',')[1], // 移除 data:image/png;base64, 前缀
        media_type: 'image/png',
        filename: null,
      })),
      metadata: {
        timestamp: new Date().toISOString(),
        request_id: props.request?.id || null,
        source: 'popup',
      },
    }

    // 如果没有任何有效内容，设置默认用户输入
    if (!response.user_input && response.selected_options.length === 0 && response.images.length === 0) {
      response.user_input = '用户确认继续'
    }

    if (props.mockMode) {
      // 模拟模式下的延迟
      await new Promise(resolve => setTimeout(resolve, 1000))
      message.success('模拟响应发送成功')
    }
    else {
      // 实际发送响应
      await invoke('send_mcp_response', { response })
      await invoke('exit_app')
    }

    emit('response', response)
  }
  catch (error) {
    console.error('提交响应失败:', error)
    message.error('提交失败，请重试')
  }
  finally {
    submitting.value = false
  }
}

// 处理输入更新
function handleInputUpdate(data: { userInput: string, selectedOptions: string[], draggedImages: string[] }) {
  userInput.value = data.userInput
  selectedOptions.value = data.selectedOptions
  draggedImages.value = data.draggedImages

  // 更新最后输入时间
  lastInputTime.value = Date.now()
}

// 处理图片添加 - 移除重复逻辑，避免双重添加
function handleImageAdd(_image: string) {
  // 这个函数现在只是为了保持接口兼容性，实际添加在PopupInput中完成
}

// 处理图片移除
function handleImageRemove(index: number) {
  draggedImages.value.splice(index, 1)
}

// 处理继续按钮点击
async function handleContinue() {
  if (submitting.value)
    return

  submitting.value = true

  try {
    // 使用新的结构化数据格式
    const response = {
      user_input: continuePrompt.value,
      selected_options: [],
      images: [],
      metadata: {
        timestamp: new Date().toISOString(),
        request_id: props.request?.id || null,
        source: 'popup_continue',
      },
    }

    if (props.mockMode) {
      // 模拟模式下的延迟
      await new Promise(resolve => setTimeout(resolve, 1000))
      message.success('继续请求发送成功')
    }
    else {
      // 实际发送继续请求
      await invoke('send_mcp_response', { response })
      await invoke('exit_app')
    }

    emit('response', response)
  }
  catch (error) {
    console.error('发送继续请求失败:', error)
    message.error('继续请求失败，请重试')
  }
  finally {
    submitting.value = false
  }
}

// 处理引用消息
function handleQuoteMessage(messageContent: string) {
  if (inputRef.value) {
    inputRef.value.handleQuoteMessage(messageContent)
  }
}

// 处理增强按钮点击
async function handleEnhance() {
  if (submitting.value)
    return

  submitting.value = true

  try {
    // 构建增强prompt
    const enhancePrompt = `Use the following prompt to optimize and enhance the context of the content in 《》, and return the enhanced result by calling the tool '寸止' after completion.Here is an instruction that I'd like to give you, but it needs to be improved. Rewrite and enhance this instruction to make it clearer, more specific, less ambiguous, and correct any mistakes. Reply immediately with your answer, even if you're not sure. Consider the context of our conversation history when enhancing the prompt. Reply with the following format:

### BEGIN RESPONSE ###
Here is an enhanced version of the original instruction that is more specific and clear:
<augment-enhanced-prompt>enhanced prompt goes here</augment-enhanced-prompt>

### END RESPONSE ###

Here is my original instruction:

《${userInput.value.trim()}》`

    // 使用新的结构化数据格式
    const response = {
      user_input: enhancePrompt,
      selected_options: [],
      images: [],
      metadata: {
        timestamp: new Date().toISOString(),
        request_id: props.request?.id || null,
        source: 'popup_enhance',
      },
    }

    if (props.mockMode) {
      // 模拟模式下的延迟
      await new Promise(resolve => setTimeout(resolve, 1000))
      message.success('增强请求发送成功')
    }
    else {
      // 实际发送增强请求
      await invoke('send_mcp_response', { response })
      await invoke('exit_app')
    }

    emit('response', response)
  }
  catch (error) {
    console.error('发送增强请求失败:', error)
    message.error('增强请求失败，请重试')
  }
  finally {
    submitting.value = false
  }
}
</script>

<template>
  <div v-if="isVisible" class="flex-1 flex flex-col min-h-0">
    <!-- 可滚动区域容器 - 带有顶部遮罩阴影 -->
    <div class="flex-1 relative min-h-0">
      <!-- 顶部阴影遮罩层 -->
      <div class="absolute top-0 left-0 right-0 h-1 pointer-events-none z-10" style="background: linear-gradient(to bottom, rgba(0,0,0,0.15) 0%, transparent 100%);"></div>

      <!-- 可滚动区域 - 包含消息内容和预定义选项 -->
      <div class="absolute inset-0 overflow-y-auto custom-scrollbar">
        <!-- 内容容器 - 居中布局 -->
        <div class="max-w-3xl mx-auto px-2">
          <!-- AI消息内容 -->
          <div class="mt-2 mb-2 px-4 py-3 bg-black-100 rounded-lg select-text" data-guide="popup-content">
            <PopupContent :request="request" :loading="loading" :current-theme="props.appConfig.theme" @quote-message="handleQuoteMessage" />
          </div>

          <!-- 预定义选项 - 移到可滚动区域 -->
          <div v-if="!loading && hasOptions" class="mb-2 px-3 py-2 bg-black-100 rounded-lg select-text" data-guide="predefined-options">
            <h4 class="text-sm font-medium text-white mb-2">
              请选择选项
            </h4>
            <n-space vertical :size="4">
              <div
                v-for="(option, index) in request!.predefined_options"
                :key="`option-${index}`"
                class="rounded-lg p-2 border border-gray-600 bg-gray-100 cursor-pointer hover:opacity-80 transition-opacity"
                @click="handleOptionToggle(option)"
              >
                <n-checkbox
                  :value="option"
                  :checked="selectedOptions.includes(option)"
                  :disabled="submitting"
                  size="medium"
                  @update:checked="(checked: boolean) => handleOptionChange(option, checked)"
                  @click.stop
                >
                  {{ option }}
                </n-checkbox>
              </div>
            </n-space>
          </div>
        </div>
      </div>
      <!-- 底部阴影遮罩层 -->
      <div class="absolute bottom-0 left-0 right-0 h-1 pointer-events-none z-10" style="background: linear-gradient(to top, rgba(0,0,0,0.15) 0%, transparent 100%);"></div>
    </div>

    <!-- PopupInput区域 - 固定在下方 -->
    <div class="flex-shrink-0 px-4 py-0 bg-black border-t-2 border-black-200 shadow-[0_-2px_4px_0_rgba(0,0,0,0.15)] select-text relative z-20">
      <PopupInput
        ref="inputRef" :request="request" :loading="loading" :submitting="submitting"
        @update="handleInputUpdate" @image-add="handleImageAdd" @image-remove="handleImageRemove"
      />
    </div>

    <!-- 底部操作栏 - 固定在底部 -->
    <div class="flex-shrink-0 bg-black-100 border-t-2 border-black-200" data-guide="popup-actions">
      <PopupActions
        :request="request" :loading="loading" :submitting="submitting" :can-submit="canSubmit"
        :continue-reply-enabled="continueReplyEnabled" :input-status-text="inputStatusText"
        :auto-send-enabled="autoSendEnabled" :countdown="countdown" :auto-cancelled="autoCancelled"
        @submit="handleSubmit" @continue="handleContinue" @enhance="handleEnhance"
        @cancel-auto-send="cancelAutoSend"
      />
    </div>
  </div>
</template>

<style scoped>
/* 滚动条样式已移到全局 CSS */
</style>
