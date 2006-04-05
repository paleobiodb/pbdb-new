var currentPanel;
                                                                                                                                                     
function showPanel(panelNum) {
    //hide visible panel, show selected panel,
    //set tab
    if (currentPanel != null) {
     hidePanel();
    }
    document.getElementById ('panel'+panelNum).style.visibility = 'visible';
	// This hopefully deals with a safari bug in which the text in textareas was being blank (not
	// showing up, even if you selected the textarea and typed).  The bug would be fixed if you
	// scrolled up and down, so we do that for the user:
	if (window.scrollBy) {
		var ua = navigator.userAgent.toLowerCase();
		var isSafari = (ua.indexOf('safari') != - 1);
		if (window.innerHeight && isSafari) {
			window.scrollBy(0, window.innerHeight);
			window.scrollBy(0, -1*window.innerHeight);
		}
	}
    currentPanel = panelNum;
    setState(panelNum);
}
                                                                                                                                                     
function hidePanel() {
    //hide visible panel, unhilite tab
    document.getElementById('panel'+currentPanel).style.visibility = 'hidden';
    var isLoading = /Loading/i;
    if (isLoading.test(document.getElementById('tab'+currentPanel).className)) {
        document.getElementById('tab'+currentPanel).className = "tabLoadingOff";
    } else {
        document.getElementById('tab'+currentPanel).className = "tabOff";
    }
    //document.getElementById
    //  ('tab'+currentPanel).style.backgroundColor =
    //  '#ffffff';
    //document.getElementById
    //  ('tab'+currentPanel).style.color = 'navy';
}
                                                                                                                                                     
function setState(tabNum) {
    var isLoading = /Loading/i;
    if (tabNum==currentPanel) {
        if (isLoading.test(document.getElementById('tab'+tabNum).className)) {
            document.getElementById('tab'+tabNum).className = "tabLoadingOn";
        } else {
            document.getElementById('tab'+tabNum).className = "tabOn";
        }
        // document.getElementById
        //   ('tab'+tabNum).style.backgroundColor =
        //   '#ddddff';
        // document.getElementById
        //   ('tab'+tabNum).style.color = 'red';
    } else {
        if (isLoading.test(document.getElementById('tab'+tabNum).className)) {
            document.getElementById('tab'+tabNum).className = "tabLoadingOff";
        } else {
            document.getElementById('tab'+tabNum).className = "tabOff";
        }
        // document.getElementById
        //   ('tab'+tabNum).style.backgroundColor =
        //   '#ffffff';
        // document.getElementById
        //   ('tab'+tabNum).style.color = 'navy';
    }
}
                                                                                                                                                     
function hover(tab) {
    //tab.style.backgroundColor = 'ddddff';
    return true;
}

function showTabText(tabNum) {
    if (tabNum==currentPanel) {
        document.getElementById('tab'+tabNum).className = "tabOn";
        showPanel(tabNum);
    } else {
        document.getElementById('tab'+tabNum).className = "tabOff";
    }
}

function hideTabText(tabNum) {
    if (tabNum==currentPanel) {
        document.getElementById('tab'+tabNum).className = "tabLoadingOn";
    } else {
        document.getElementById('tab'+tabNum).className = "tabLoadingOff";
    }
} 

