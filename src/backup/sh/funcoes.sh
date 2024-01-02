#!/usr/bin/env sh

instalar(){

    echo "==> Checkando se o $1 está instalado"
    if ! command -v $1 &> /dev/null;
    then
        bash $1/requerimentos.sh
    fi
}

iniciar_projecto_packer(){
  echo "==> Iniciando o projecto packer $1 $2"
  packer init $2
  cd docker
  sudo docker compose up --build --force-recreate --remove-orphans
  cd ..
}
validar_template_packer(){
  echo "==> Validando o template packer $1"
  packer validate $1
}