#!/bin/bash

# Define executable files path
MENU_SH=/usrdata/quecdeck/console/menu

# Display Messages in Colors
display_random_color() {
    local msg="$1"
    local colors=(33 34 35 36 37)  # ANSI color codes for yellow, blue, magenta, cyan, white
    local num_colors=${#colors[@]}
    local random_color_index=$(($RANDOM % num_colors))  # Pick a random index from the colors array
    echo -e "\033[${colors[$random_color_index]}m$msg\033[0m"
}

display_green() {
    echo -e "\033[0;32m$1\033[0m"
}

display_red() {
    echo -e "\033[0;31m$1\033[0m"
}

# Menus

toolkit_menu() {
    while true; do
        display_random_color "Run the Toolkit"
        display_green "Select an option:"
        echo "------------------"
        display_green "1. Get and run the Toolkit"
        display_random_color "2. Exit (Enter Root Shell)"
        echo
        read -p "Select an option (1-2): " option

        case "$option" in
            1) cd /tmp && wget -O quecdeck.sh https://raw.githubusercontent.com/megakerw/QuecDeck/main/quecdeck.sh && chmod +x quecdeck.sh && ./quecdeck.sh && cd / ;;
            2) break ;;
            *) echo "Invalid option. Please try again." ;;
        esac
    done
}

apps_menu() {
    while true; do
        display_random_color "Run a modem App"
        display_green "Select an option:"
        echo "------------------"
        display_random_color "1. Open File Browser/Editor (mc)"
        display_random_color "2. View Used/Available space"
        display_random_color "3. Open Task Manager/View CPU Load"
        display_green "4. Go Back"
        echo
        read -p "Select an option (1-4): " option

        case "$option" in
            1) mc ;;
            2) dfc ;;
            3) htop ;;
            4) break ;;
            *) echo "Invalid option. Please try again." ;;
        esac
    done
}

settings_menu() {
    while true; do
        display_random_color "Password Management"
        display_green "Select an option:"
        echo "------------------"
        display_green "1. Change quecdeck (admin) password"
        display_green "2. Change developer access (devadmin) password"
        display_green "3. Change root password (shell/ssh/console)"
        display_green "4. Go back"
        echo
        read -p "Select an option (1-4): " option

        case "$option" in
            1) quecdeckpasswd ;;
            2) quecdeckdevpasswd ;;
            3) passwd ;;
            4) break ;;
            *) echo "Invalid option. Please try again." ;;
        esac
    done
}

main_menu() {
    while true; do
        display_green "Welcome to QuecDeck Console"
        display_green "To get back to this from the root shell, just type 'menu'"
        display_green "Select an option:"
        echo "------------------"
        display_random_color "1. Apps"
        display_random_color "2. Password Management"
        display_random_color "3. Toolkit"
        display_random_color "4. Exit (Enter Root Shell)"
        echo
        read -p "Select an option (1-4): " option

        case "$option" in
            1) apps_menu ;;
            2) settings_menu ;;
            3) toolkit_menu ;;
            4) break ;;
            *) echo "Invalid option. Please try again." ;;
        esac
    done
}

main_menu
