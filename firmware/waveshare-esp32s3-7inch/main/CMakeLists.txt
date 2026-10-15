idf_component_register(SRCS "main.c" "board.c" "touch.c" "ui.c" "usb_link.c" "uart_link.c" "wifi_link.c" "secure_link.c" "ble_link.c"
                       INCLUDE_DIRS "."
                       REQUIRES trackpad_core esp_lcd esp_driver_i2c esp_driver_gpio esp_driver_uart esp_timer nvs_flash esp_wifi esp_netif esp_event mbedtls lwip bt)
# lv_obj_add_flag/remove_flag are deprecated only in the newest LVGL 9 releases;
# they are kept because they compile across every 9.x version.
target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-deprecated-declarations)

