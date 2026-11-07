package com.example.map

import io.flutter.embedding.android.FlutterActivity
import android.os.Bundle

// 新增全局单例，保存当前的Activity
object MainActivityInstance {
    lateinit var current: MainActivity
}

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 把当前Activity赋值给全局实例
        MainActivityInstance.current = this
    }
}