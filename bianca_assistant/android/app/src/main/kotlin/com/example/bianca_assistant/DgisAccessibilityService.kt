package com.example.bianca_assistant

import android.accessibilityservice.AccessibilityService
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class DgisAccessibilityService : AccessibilityService() {
    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (!isArmed() || event?.packageName != DGIS_PACKAGE) return
        val root = rootInActiveWindow ?: return
        if (root.packageName != DGIS_PACKAGE) return
        if (clickStartButton(root)) cancelAutoStart()
    }

    override fun onInterrupt() = Unit

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        cancelAutoStart()
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        cancelAutoStart()
        instance = null
        super.onDestroy()
    }

    private fun clickStartButton(root: AccessibilityNodeInfo): Boolean {
        val nodes = ArrayDeque<AccessibilityNodeInfo>()
        nodes.add(root)
        while (nodes.isNotEmpty()) {
            val node = nodes.removeFirst()
            if (node.text?.toString()?.trim()?.equals(START_BUTTON, ignoreCase = true) == true ||
                node.contentDescription?.toString()?.trim()
                    ?.equals(START_BUTTON, ignoreCase = true) == true
            ) {
                var target: AccessibilityNodeInfo? = node
                repeat(MAX_CLICKABLE_PARENTS) {
                    if (target?.isClickable != true) target = target?.parent
                }
                target?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                return true
            }
            for (index in 0 until node.childCount) {
                node.getChild(index)?.let(nodes::add)
            }
        }
        return false
    }

    companion object {
        private const val DGIS_PACKAGE = "ru.dublgis.dgismobile"
        private const val START_BUTTON = "В путь"
        private const val MAX_CLICKABLE_PARENTS = 6
        private const val ARM_TIMEOUT_MS = 45_000L
        private val lock = Object()

        @Volatile
        private var instance: DgisAccessibilityService? = null
        private var armedUntil = 0L

        fun armAutoStart(): Boolean {
            if (instance == null) return false
            synchronized(lock) {
                armedUntil = SystemClock.elapsedRealtime() + ARM_TIMEOUT_MS
            }
            return true
        }

        fun cancelAutoStart() {
            synchronized(lock) {
                armedUntil = 0L
            }
        }

        fun isEnabled(): Boolean = instance != null

        private fun isArmed(): Boolean = synchronized(lock) {
            armedUntil > SystemClock.elapsedRealtime()
        }
    }
}
