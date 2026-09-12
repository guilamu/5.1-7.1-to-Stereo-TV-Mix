@echo off
rem ---------------------------------------------------------------------------
rem  Lanceur "souris" de Convert-SurroundToStereo.ps1
rem
rem    - glisser-deposer : deposer un ou plusieurs fichiers / dossiers sur ce .cmd
rem    - double-clic     : le script demande ensuite quoi traiter (Entree = dossier courant)
rem
rem  Windows ne sait faire ni l'un ni l'autre avec un .ps1 : un double-clic l'ouvre
rem  dans le Bloc-notes et l'explorateur refuse le depot. D'ou ce .cmd, qui sert
rem  aussi a garder la fenetre ouverte a la fin (pause) pour lire le compte rendu.
rem  Messages sans accent : la console n'est pas en UTF-8 par defaut.
rem
rem  Copyright (C) 2026 Guillaume - SPDX-License-Identifier: AGPL-3.0-or-later
rem  Logiciel libre distribue SANS AUCUNE GARANTIE ; voir le fichier LICENSE.
rem ---------------------------------------------------------------------------
setlocal enabledelayedexpansion
title Conversion 5.1 / 7.1 vers stereo TV

set "PS1=%~dp0Convert-SurroundToStereo.ps1"
if not exist "%PS1%" (
    echo Convert-SurroundToStereo.ps1 est introuvable a cote de ce fichier :
    echo   %~dp0
    echo Garder les deux fichiers dans le meme dossier.
    echo.
    pause
    exit /b 1
)

rem Chaque chemin depose devient un element d'un tableau PowerShell, entre apostrophes
rem (les apostrophes presentes dans un nom sont doublees). Passer par -Command plutot que
rem -File : avec -File, PowerShell 5.1 ne reconstruit pas un tableau a partir de plusieurs
rem arguments et -Path recevrait une seule chaine.
set "ARGS="
:collect
if "%~1"=="" goto run
set "ITEM=%~1"
set "ITEM=!ITEM:'=''!"
if defined ARGS (set "ARGS=!ARGS!,'!ITEM!'") else (set "ARGS='!ITEM!'")
shift
goto collect

:run
set "PSFILE=%PS1:'=''%"
if defined ARGS (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%PSFILE%' -Ask -Path @(%ARGS%)"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%PSFILE%' -Ask"
)
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo Code de sortie : %RC%  (au moins un fichier en erreur)
pause
exit /b %RC%
