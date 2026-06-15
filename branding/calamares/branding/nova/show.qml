import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation {
    id: presentation

    Timer {
        interval: 5000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: "#170B33" }
        Text {
            anchors.centerIn: parent
            color: "#FFFFFF"
            font.pixelSize: 30
            horizontalAlignment: Text.AlignHCenter
            text: "Welcome to NOVA"
        }
    }

    Slide {
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: "#241046" }
        Text {
            anchors.centerIn: parent
            color: "#FFFFFF"
            font.pixelSize: 24
            horizontalAlignment: Text.AlignHCenter
            text: "Fast. Beautiful. Yours.\nSetting things up…"
        }
    }

    Slide {
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: "#170B33" }
        Text {
            anchors.centerIn: parent
            color: "#FFFFFF"
            font.pixelSize: 24
            horizontalAlignment: Text.AlignHCenter
            text: "Almost there — NOVA will restart when it's ready."
        }
    }
}
